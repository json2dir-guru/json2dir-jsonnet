# json2dir-jsonnet

json2dir in Jsonnet: `json2dir.jsonnet` (go-jsonnet, std library only) validates the JSON document and emits a shell script, and the POSIX sh launcher `json2dir` runs that script.

    JSON2DIR_JSONNET=/path/to/jsonnet ./json2dir < tree.json
