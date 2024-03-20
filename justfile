@run *args="":
    zig build && ./zig-out/bin/bril-zig {{args}}

run-with bril-file *args="":
    cat {{bril-file}} | bril2json | just run {{args}}

test *args="":
    zig build && turnt {{args}} test/**/*.bril
