# Optional Graphify navigation

Use the source and ordinary search as usual. Graphify can help trace relationships when it is already available. The older checkout's exclusion file informed [the project exclusions](../.graphifyignore). Its graph output, local hooks and settings stay local.

Index only a disposable export of reviewed, committed source. Keep scans away from full worktrees, home directories, builds and private data. Review the export's path list first. Include only ordinary source files and the exclusion file. This example uses the current Notes app source:

```bash
git ls-tree -r HEAD -- lib
notes_graph_dir=$(mktemp -d)
git archive HEAD -- .graphifyignore lib | tar -x -C "$notes_graph_dir"
(
  cd "$notes_graph_dir"
  graphify update .
  graphify query "How does sync send changes?"
)
```

`update` uses local code extraction. The exclusions cover private directories, database files, credentials, signing material, generated files and graph output. The narrow export is the primary boundary because exclusion patterns cannot identify every possible credential filename. Use a fresh reviewed export to refresh the graph. Keep outputs out of commits, CI and handovers. Check graph results against the current source. See [Graphify upstream](https://github.com/Graphify-Labs/graphify).
