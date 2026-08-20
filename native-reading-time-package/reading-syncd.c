#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef BASE
#define BASE "/mnt/us/reading-time"
#endif
#define JOURNAL BASE "/sync-events.tsv"
#define DATA BASE "/reading-time.tsv"
#define SESSIONS BASE "/reading-sessions.tsv"
#define DEVICE BASE "/device-id"
#define TRIGGER BASE "/sync-trigger"
#define STATUS BASE "/sync-status.tsv"
#define PIDFILE BASE "/reading-sync.pid"
#define LOCKDIR BASE "/.data-lock"
#define LOGFILE BASE "/sync.log"
#ifndef UDP_PORT
#define UDP_PORT 17687
#endif
#ifndef TCP_PORT
#define TCP_PORT 17688
#endif
#define MAX_PEERS 16
#define MAX_LINE 8192
#define MAGIC_DISCOVER "KRR_DISCOVER\t1\t"
#define MAGIC_HERE "KRR_HERE\t1\t"
#define HEADER "event_id\torigin\tsequence\ttype\tdate\tstart\tend\tbook_id\tseconds\ttitle\tcreated_at\n"

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t trigger_requested = 0;
static char device_id[96];

typedef struct { char **v; size_t n, cap; } Lines;
typedef struct { struct sockaddr_in addr; char id[96]; } Peer;

static char *split_next(char **cursor, const char *delims) {
    char *start, *end;
    if (!cursor || !*cursor) return NULL;
    start = *cursor; end = strpbrk(start, delims);
    if (end) { *end = 0; *cursor = end + 1; } else *cursor = NULL;
    return start;
}

static void stop_now(int sig) { (void)sig; running = 0; }
static void request_sync(int sig) { (void)sig; trigger_requested = 1; }
static void logmsg(const char *msg) {
    FILE *f = fopen(LOGFILE, "a"); time_t now = time(NULL);
    if (f) { fprintf(f, "%ld: %s\n", (long)now, msg); fclose(f); }
}
static void status_write(const char *state, int peers, const char *message) {
    char tmp[256]; snprintf(tmp, sizeof(tmp), "%s.tmp", STATUS);
    FILE *f = fopen(tmp, "w"); if (!f) return;
    fprintf(f, "state\tpeers\tupdated\tmessage\n%s\t%d\t%ld\t%s\n", state, peers, (long)time(NULL), message);
    fclose(f); rename(tmp, STATUS);
}
static int lock_data(void) {
    int i; for (i=0;i<80;i++) {
        if (mkdir(LOCKDIR,0700)==0) { FILE *f=fopen(LOCKDIR "/pid","w");if(f){fprintf(f,"%ld\n",(long)getpid());fclose(f);}return 0; }
        { FILE *f=fopen(LOCKDIR "/pid","r");long pid=0;if(f){fscanf(f,"%ld",&pid);fclose(f);}if(pid>1&&kill((pid_t)pid,0)&&errno==ESRCH){unlink(LOCKDIR "/pid");rmdir(LOCKDIR);} }
        usleep(50000);
    }
    return -1;
}
static void unlock_data(void) { unlink(LOCKDIR "/pid"); rmdir(LOCKDIR); }
static uint64_t fnv1a(const char *s) {
    uint64_t h=UINT64_C(1469598103934665603); while (*s) { h^=(unsigned char)*s++; h*=UINT64_C(1099511628211); } return h;
}
static void clean_field(char *s) { while (*s) { if (*s=='\t'||*s=='\r'||*s=='\n') *s=' '; s++; } }
static int lines_has_id(const Lines *a, const char *line) {
    size_t idlen=strcspn(line,"\t"),i;
    for(i=0;i<a->n;i++) if(strncmp(a->v[i],line,idlen)==0 && a->v[i][idlen]=='\t') return 1;
    return 0;
}
static int lines_add(Lines *a, const char *line) {
    char *p; if(!line[0]||lines_has_id(a,line)) return 0;
    if(a->n==a->cap){size_t nc=a->cap?a->cap*2:256;char **nv=realloc(a->v,nc*sizeof(*nv));if(!nv)return -1;a->v=nv;a->cap=nc;}
    p=strdup(line);if(!p)return -1;a->v[a->n++]=p;return 1;
}
static void lines_free(Lines *a){size_t i;for(i=0;i<a->n;i++)free(a->v[i]);free(a->v);memset(a,0,sizeof(*a));}
static int journal_load(Lines *a) {
    FILE *f=fopen(JOURNAL,"r");char line[MAX_LINE];if(!f)return 0;
    while(fgets(line,sizeof(line),f)){size_t n=strlen(line);while(n&&(line[n-1]=='\n'||line[n-1]=='\r'))line[--n]=0;if(strncmp(line,"event_id\t",9))lines_add(a,line);}
    fclose(f);return 0;
}
static int journal_save(const Lines *a) {
    char tmp[256];size_t i;snprintf(tmp,sizeof(tmp),"%s.tmp",JOURNAL);FILE *f=fopen(tmp,"w");if(!f)return -1;
    fputs(HEADER,f);for(i=0;i<a->n;i++)fprintf(f,"%s\n",a->v[i]);
    if(fclose(f)||rename(tmp,JOURNAL))return -1;return 0;
}
static void legacy_import_file(Lines *a,const char *path,char type) {
    FILE *f=fopen(path,"r");char line[MAX_LINE];unsigned long no=0;if(!f)return;
    while(fgets(line,sizeof(line),f)){char raw[MAX_LINE],*cols[6],*p;int n=0;uint64_t h;no++;if(no==1)continue;
        snprintf(raw,sizeof(raw),"%c:%lu:%s",type,no,line);h=fnv1a(raw);
        p=line;while(n<6){char*q=split_next(&p,"\t");if(!q)break;cols[n++]=q;} if((type=='D'&&n<4)||(type=='S'&&n<5))continue;
        clean_field(cols[n-1]);
        if(type=='D')snprintf(raw,sizeof(raw),"legacy-%016llx\tlegacy\t0\tD\t%s\t\t\t%s\t%s\t%s\t0",(unsigned long long)h,cols[0],cols[1],cols[2],cols[3]);
        else snprintf(raw,sizeof(raw),"legacy-%016llx\tlegacy\t0\tS\t%s\t%s\t%s\t%s\t0\t%s\t0",(unsigned long long)h,cols[0],cols[1],cols[2],cols[3],cols[4]);
        lines_add(a,raw);
    } fclose(f);
}
static void migrate_legacy(void) {
    Lines a={0};struct stat st;if(stat(JOURNAL,&st)==0&&st.st_size>(off_t)strlen(HEADER))return;
    if(lock_data())return;journal_load(&a);legacy_import_file(&a,DATA,'D');legacy_import_file(&a,SESSIONS,'S');journal_save(&a);lines_free(&a);unlock_data();logmsg("legacy data imported");
}
static void rebuild_views(const Lines *a) {
    char dt[256],st[256];size_t i;snprintf(dt,sizeof(dt),"%s.tmp",DATA);snprintf(st,sizeof(st),"%s.tmp",SESSIONS);
    FILE *df=fopen(dt,"w"),*sf=fopen(st,"w");if(!df||!sf){if(df)fclose(df);if(sf)fclose(sf);return;}
    fputs("date\tbook_id\tseconds\ttitle\n",df);fputs("date\tstart\tend\tbook_id\ttitle\n",sf);
    for(i=0;i<a->n;i++){char *copy=strdup(a->v[i]),*p=copy,*c[11];int n=0;if(!copy)continue;while(n<11){char*q=split_next(&p,"\t");if(!q)break;c[n++]=q;}
        if(n>=10&&c[3][0]=='D')fprintf(df,"%s\t%s\t%s\t%s\n",c[4],c[7],c[8],c[9]);
        else if(n>=10&&c[3][0]=='S')fprintf(sf,"%s\t%s\t%s\t%s\t%s\n",c[4],c[5],c[6],c[7],c[9]);free(copy);}
    fclose(df);fclose(sf);rename(dt,DATA);rename(st,SESSIONS);
}
static int merge_text(const char *buf,size_t len) {
    Lines a={0};char *copy=malloc(len+1),*p,*line;int added=0;if(!copy)return -1;memcpy(copy,buf,len);copy[len]=0;
    if(lock_data()){free(copy);return -1;}journal_load(&a);p=copy;
    while((line=split_next(&p,"\n"))!=NULL){size_t n=strlen(line);while(n&&line[n-1]=='\r')line[--n]=0;if(strncmp(line,"event_id\t",9)){int r=lines_add(&a,line);if(r>0)added+=r;}}
    if(added){journal_save(&a);rebuild_views(&a);}lines_free(&a);unlock_data();free(copy);return added;
}
static char *read_all(size_t *len) {
    FILE *f=fopen(JOURNAL,"r");char *b;long n;if(!f)return NULL;fseek(f,0,SEEK_END);n=ftell(f);rewind(f);if(n<0||n>32*1024*1024){fclose(f);return NULL;}b=malloc((size_t)n+1);if(!b){fclose(f);return NULL;}*len=fread(b,1,(size_t)n,f);b[*len]=0;fclose(f);return b;
}
static int send_all(int fd,const void *buf,size_t n){const char*p=buf;while(n){ssize_t r=send(fd,p,n,0);if(r<=0)return -1;p+=r;n-=r;}return 0;}
static int recv_line(int fd,char *b,size_t cap){size_t n=0;while(n+1<cap){char c;ssize_t r=recv(fd,&c,1,0);if(r<=0)return -1;if(c=='\n'){b[n]=0;return 0;}b[n++]=c;}return -1;}
static void serve_client(int fd) {
    char cmd[128];struct timeval tv={5,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&tv,sizeof(tv));if(recv_line(fd,cmd,sizeof(cmd)))return;
    if(!strcmp(cmd,"GET\t1")){size_t n=0;char*b=read_all(&n),h[64];if(!b)return;snprintf(h,sizeof(h),"OK\t%zu\n",n);send_all(fd,h,strlen(h));send_all(fd,b,n);free(b);}
    else if(!strncmp(cmd,"PUSH\t1\t",7)){long n=strtol(cmd+7,NULL,10);char*b;size_t got=0;if(n<0||n>32*1024*1024)return;b=malloc((size_t)n+1);if(!b)return;while(got<(size_t)n){ssize_t r=recv(fd,b+got,(size_t)n-got,0);if(r<=0)break;got+=(size_t)r;}if(got==(size_t)n){b[got]=0;merge_text(b,got);send_all(fd,"OK\n",3);}free(b);}
}
static int connect_peer(const struct sockaddr_in *a){int fd=socket(AF_INET,SOCK_STREAM,0);struct timeval tv={3,0};if(fd<0)return -1;setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&tv,sizeof(tv));if(connect(fd,(const struct sockaddr*)a,sizeof(*a))){close(fd);return -1;}return fd;}
static int peer_get(const Peer*p){int fd=connect_peer(&p->addr);char h[64],*b;long n;size_t got=0;if(fd<0)return -1;if(send_all(fd,"GET\t1\n",6)||recv_line(fd,h,sizeof(h))||strncmp(h,"OK\t",3)){close(fd);return -1;}n=strtol(h+3,NULL,10);if(n<0||n>32*1024*1024){close(fd);return -1;}b=malloc((size_t)n+1);if(!b){close(fd);return -1;}while(got<(size_t)n){ssize_t r=recv(fd,b+got,(size_t)n-got,0);if(r<=0)break;got+=(size_t)r;}close(fd);if(got==(size_t)n)merge_text(b,got);free(b);return got==(size_t)n?0:-1;}
static int peer_push(const Peer*p){size_t n=0;char*b=read_all(&n),h[64],reply[32];int fd;if(!b)return -1;fd=connect_peer(&p->addr);if(fd<0){free(b);return -1;}snprintf(h,sizeof(h),"PUSH\t1\t%zu\n",n);if(send_all(fd,h,strlen(h))||send_all(fd,b,n)||recv_line(fd,reply,sizeof(reply))||strcmp(reply,"OK")){close(fd);free(b);return -1;}close(fd);free(b);return 0;}
static int peer_exists(Peer*p,int n,const char*id){int i;for(i=0;i<n;i++)if(!strcmp(p[i].id,id))return 1;return 0;}
static int discover(int udp,Peer *peers) {
    struct sockaddr_in dst;char msg[160],buf[256];int yes=1,n=0,i;snprintf(msg,sizeof(msg),"%s%s\n",MAGIC_DISCOVER,device_id);
    memset(&dst,0,sizeof(dst));dst.sin_family=AF_INET;dst.sin_port=htons(UDP_PORT);dst.sin_addr.s_addr=htonl(INADDR_BROADCAST);setsockopt(udp,SOL_SOCKET,SO_BROADCAST,&yes,sizeof(yes));sendto(udp,msg,strlen(msg),0,(struct sockaddr*)&dst,sizeof(dst));
    for(i=0;i<12;i++){fd_set rf;struct timeval tv={0,100000};FD_ZERO(&rf);FD_SET(udp,&rf);if(select(udp+1,&rf,NULL,NULL,&tv)>0){struct sockaddr_in from;socklen_t fl=sizeof(from);ssize_t r=recvfrom(udp,buf,sizeof(buf)-1,0,(struct sockaddr*)&from,&fl);if(r>0){char*id;buf[r]=0;if(!strncmp(buf,MAGIC_HERE,strlen(MAGIC_HERE))){id=buf+strlen(MAGIC_HERE);id[strcspn(id,"\t\r\n")]=0;if(strcmp(id,device_id)&&!peer_exists(peers,n,id)&&n<MAX_PEERS){peers[n].addr=from;peers[n].addr.sin_port=htons(TCP_PORT);snprintf(peers[n].id,sizeof(peers[n].id),"%s",id);n++;}}else if(!strncmp(buf,MAGIC_DISCOVER,strlen(MAGIC_DISCOVER))){char out[160];id=buf+strlen(MAGIC_DISCOVER);id[strcspn(id,"\r\n")]=0;if(strcmp(id,device_id)){snprintf(out,sizeof(out),"%s%s\t%d\n",MAGIC_HERE,device_id,TCP_PORT);sendto(udp,out,strlen(out),0,(struct sockaddr*)&from,fl);}}}}}
    return n;
}
static void sync_now(int udp) {
    Peer peers[MAX_PEERS];int n,i,ok=0;status_write("syncing",0,"正在同步");n=discover(udp,peers);
    for(i=0;i<n;i++)if(!peer_get(&peers[i]))ok++;
    for(i=0;i<n;i++)peer_push(&peers[i]);
    if(ok){char m[64];snprintf(m,sizeof(m),"已同步 %d 台设备",ok);status_write("ok",ok,m);}
    else status_write("none",0,"未发现设备");unlink(TRIGGER);
}
static void udp_reply(int udp) {
    struct sockaddr_in from;socklen_t fl=sizeof(from);char b[256],out[160];ssize_t r=recvfrom(udp,b,sizeof(b)-1,0,(struct sockaddr*)&from,&fl);if(r<=0)return;b[r]=0;
    if(!strncmp(b,MAGIC_DISCOVER,strlen(MAGIC_DISCOVER))){char*id=b+strlen(MAGIC_DISCOVER);id[strcspn(id,"\r\n")]=0;if(strcmp(id,device_id)){snprintf(out,sizeof(out),"%s%s\t%d\n",MAGIC_HERE,device_id,TCP_PORT);sendto(udp,out,strlen(out),0,(struct sockaddr*)&from,fl);}}
}
static void load_device_id(void){FILE*f=fopen(DEVICE,"r");if(f){fgets(device_id,sizeof(device_id),f);fclose(f);device_id[strcspn(device_id,"\r\n")]=0;}if(!device_id[0])snprintf(device_id,sizeof(device_id),"unknown-%ld",(long)getpid());}
int main(int argc, char **argv) {
    int udp,tcp,yes=1;struct sockaddr_in a;struct sigaction sa;FILE *pf;signal(SIGTERM,stop_now);signal(SIGINT,stop_now);memset(&sa,0,sizeof(sa));sa.sa_handler=request_sync;sigemptyset(&sa.sa_mask);sigaction(SIGUSR1,&sa,NULL);signal(SIGPIPE,SIG_IGN);load_device_id();migrate_legacy();
    if(argc>1&&!strcmp(argv[1],"--migrate-only"))return 0;
    udp=socket(AF_INET,SOCK_DGRAM,0);tcp=socket(AF_INET,SOCK_STREAM,0);if(udp<0||tcp<0)return 1;setsockopt(udp,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));setsockopt(tcp,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    memset(&a,0,sizeof(a));a.sin_family=AF_INET;a.sin_addr.s_addr=htonl(INADDR_ANY);a.sin_port=htons(UDP_PORT);if(bind(udp,(struct sockaddr*)&a,sizeof(a)))return 2;a.sin_port=htons(TCP_PORT);if(bind(tcp,(struct sockaddr*)&a,sizeof(a))||listen(tcp,4))return 3;
    pf=fopen(PIDFILE,"w");if(pf){fprintf(pf,"%ld\n",(long)getpid());fclose(pf);}status_write("idle",0,"等待同步");logmsg("reading-syncd started");
    while(running){fd_set rf;int max=udp>tcp?udp:tcp;if(trigger_requested||access(TRIGGER,F_OK)==0){trigger_requested=0;sync_now(udp);continue;}FD_ZERO(&rf);FD_SET(udp,&rf);FD_SET(tcp,&rf);if(select(max+1,&rf,NULL,NULL,NULL)>0){if(FD_ISSET(udp,&rf))udp_reply(udp);if(FD_ISSET(tcp,&rf)){int c=accept(tcp,NULL,NULL);if(c>=0){serve_client(c);close(c);}}}}
    unlink(PIDFILE);close(udp);close(tcp);logmsg("reading-syncd stopped");return 0;
}
