# Runs the programs that `test/cross/matrix.jl` kept, where they can run: `julia test/cross/run.jl dir`. It needs only Julia (and Node.js 24 or later, for WebAssembly: `STATIC_RUNTIME_NODE`, or `node`, or it is fetched).
# `dir/<host>/<triple>/<program>/` was made on `<host>` for `<triple>`. The triples that this machine can run (its system and its architecture; x86-64 macOS on Apple Silicon, by Rosetta; WebAssembly, by Node.js)
# are checked: each program has to do what the native one did (`test/cross/check.jl`). Exits with a status that is not 0 if one did not.

include("host.jl")
include("check.jl")

dir = abspath(ARGS[1])
rows = NamedTuple[]
for made_on in sort(readdir(dir)), triple in sort(readdir(joinpath(dir, made_on)))
    runs_here(triple) || continue
    println("\n## made on ", made_on, " for ", triple)
    failures = check_programs(joinpath(dir, made_on, triple); node = something(node_command(), `node`))
    count = length(readdir(joinpath(dir, made_on, triple)))
    push!(rows, (; made_on, triple, count, failures, ok = isempty(failures)))
end

host = string(host_arch(), "-", host_system())
status(r) = r.ok ? "ok" : string("FAILS: ", join((f.name for f in r.failures), ", "))
table = string("| made on | for | programs | run on `", host, "` |\n|:--|:--|:--|:--|\n", join(("| $(r.made_on) | `$(r.triple)` | $(r.count) | $(status(r)) |" for r in rows), "\n"), "\n")
# what the first of the programs that failed did, and what it should have done: the standard output, the standard error and the exit status (truncated)
short(x) = (s = repr(x); length(s) > 400 ? string(first(s, 400), "...") : s)
details = join((string("\n**made on ", r.made_on, " for `", r.triple, "`, `", f.name, "`**\n\n    got   ", short(f.got), "\n    want  ", short(f.want), "\n") for r in rows if !r.ok for f in first(r.failures, 3)), "")
println("\n", isempty(rows) ? "none of those that were made are for this machine" : table, details)
haskey(ENV, "GITHUB_STEP_SUMMARY") && open(io -> println(io, "\n### Programs run on ", host, "\n\n", isempty(rows) ? "none of those that were made are for this machine" : string(table, details)), ENV["GITHUB_STEP_SUMMARY"], "a")
all(r -> r.ok, rows) || exit(1)
