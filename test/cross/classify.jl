# Groups the reasons in a report of `test/cross/survey.jl`: `julia test/cross/classify.jl <report.tsv>...`
function classify(paths)
    rows = [split(l, '\t'; limit = 4) for p in paths for l in eachline(p) if count('\t', l) >= 3]
    counts = Dict{String,Int}()
    for r in rows; counts[r[3]] = get(counts, r[3], 0) + 1; end
    println(length(rows), " cases: ", join(("$k $v" for (k, v) in sort(collect(counts); by = last, rev = true)), ", "))
    reasons = Dict{String,Vector{String}}()
    for r in rows
        r[3] == "ok" && continue
        d = r[4]
        key = if (m = match(r"the program uses (`[^`]+`(?:, `[^`]+`)*)", d)) !== nothing
            "needs host function(s): " * m.captures[1]
        elseif occursin("Float16", d); "Float16 vectors"
        elseif (m = match(r"(LoadError|MethodError|ErrorException|ArgumentError|Dynamic behavior[^.]*|undefined symbol[^.]*|unsupported[^.]*)", d)) !== nothing
            string(r[3], ": ", first(m.match, 70))
        else
            string(r[3], ": ", first(d, 70))
        end
        push!(get!(reasons, key, String[]), r[1] * ":" * r[2])
    end
    for (k, v) in sort(collect(reasons); by = x -> -length(x[2]))
        println("\n", length(v), "  ", k)
        for c in first(v, 4); println("     ", c); end
    end
end
classify(ARGS)
