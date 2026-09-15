ObjC.import("Foundation");

function run(argv) {
    var sourcePath = argv[0];
    var source = $.NSString.stringWithContentsOfFileEncodingError(
        sourcePath,
        $.NSUTF8StringEncoding,
        null
    ).js;
    var rows = [];
    var i;
    for (i = 0; i < 12; i++) {
        rows.push({date:"2026-08-01", id:"L-" + i, seconds:60, title:"L" + i});
    }
    rows.push({date:"2026-08-01", id:"REMOTE", seconds:60, title:"R"});

    source = source.replace(/\}\)\(\);\s*$/, [
        "tab='total';knownToday=todayKey();selectedDate='2026-08-01';lastOpenToken='old';",
        "applyOpenState('date\\ttoken\\n2026-08-15\\tnew\\n');",
        "if(selectedDate!=='2026-08-15')throw new Error('new app-open token did not reset daily date');",
        "selectedDate='2026-08-14';applyOpenState('date\\ttoken\\n2026-08-15\\tnew\\n');",
        "if(selectedDate!=='2026-08-14')throw new Error('same app-open token reset current-session selection');",
        "data=TEST_ROWS;sessions=[];localBooks={};",
        "for(var z=0;z<12;z++)localBooks[bookKey('L-'+z)]=1;",
        "bookScope='local';",
        "if(booksForScope().length!==12)throw new Error('local filter failed');",
        "if(Math.ceil(booksForScope().length/bookPageSize())!==1)throw new Error('local pagination failed');",
        "bookScope='all';",
        "if(booksForScope().length!==13)throw new Error('all filter failed');",
        "if(Math.ceil(booksForScope().length/bookPageSize())!==2)throw new Error('all pagination failed');",
        "})();"
    ].join(""));

    new Function("document", "window", "XMLHttpRequest", "TEST_ROWS", source)(
        {readyState:"loading", addEventListener:function(){}},
        {},
        function(){},
        rows
    );
    return "filter smoke test passed";
}
