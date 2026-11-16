# What runs the fuzz tests: each seed is a process of its own (`case.jl`), with a time limit, a few at a time.
#
# A case that compiles a program that makes inference run for minutes is a failure that the process that runs the tests can not see, and can not stop: so a case is not run in it. The process is `julia`
# with the environment of the tests, and it is the only one that is stopped when the time is up (`FUZZ_TIME_LIMIT`, in seconds: 120 by default, which is far more than a case takes).
#
# The environment variables:
#   FUZZ_SEEDS        the seeds to run, instead of the pinned ones and the random ones: `0x688,0x9ba283a794c4a8` (hex or decimal), and `1:300` is a range
#   FUZZ_COUNT        how many random seeds for each kind of fuzzing (20 by default, `0` for none)
#   FUZZ_TIME_LIMIT   seconds for a case (120)
#   FUZZ_WORKERS      how many cases run at the same time (half of the CPUs, at most 4)
#   FUZZ_VERBOSE      say what the cases that are not wrong, but are not accepted, were (DispatchFuzz)
# A seed that fails, or does not finish, is written with the command that runs it again by itself, with no time limit.

const FUZZ_DIR = @__DIR__

parse_fuzz_seed(s::AbstractString) = (t = strip(s); startswith(t, "0x") ? parse(UInt, t) : parse(UInt, t))

# `0x688,12,1:3` => [0x688, 12, 1, 2, 3]
function parse_fuzz_seeds(spec::AbstractString)
    seeds = UInt[]
    for part in split(spec, ',')
        isempty(strip(part)) && continue
        if occursin(':', part) && !startswith(strip(part), "0x")
            a, b = split(part, ':')
            append!(seeds, parse_fuzz_seed(a):parse_fuzz_seed(b))
        else
            push!(seeds, parse_fuzz_seed(part))
        end
    end
    return seeds
end

fuzz_time_limit() = parse(Float64, get(ENV, "FUZZ_TIME_LIMIT", "120"))
fuzz_workers() = (v = get(ENV, "FUZZ_WORKERS", ""); clamp(isempty(v) ? Sys.CPU_THREADS ÷ 2 : parse(Int, v), 1, 10))

hexseed(seed::UInt) = string("0x", string(seed; base = 16))

# The command that runs one case by itself (in this process, with no limit)
function fuzz_repro_command(kind::AbstractString, seed::UInt)
    return string("julia --project=test test/fuzz/case.jl ", kind, " ", hexseed(seed))
end

struct FuzzResult
    seed::UInt
    ok::Bool
    timed_out::Bool
    seconds::Float64
    detail::String
end

# Run the case of `kind` for `seed` in a process, for at most `limit` seconds
function run_fuzz_case(kind::AbstractString, seed::UInt; limit::Float64 = fuzz_time_limit())
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no $(joinpath(FUZZ_DIR, "case.jl")) $kind $(hexseed(seed))`
    out = Pipe()
    started = time()
    proc = run(pipeline(cmd; stdout = out, stderr = out); wait = false)
    close(out.in)
    reader = @async read(out, String)
    timed_out = false
    while process_running(proc)
        if time() - started > limit
            timed_out = true
            kill(proc) # (this process only: SIGTERM, and SIGKILL if it does not stop)
            for _ in 1:50
                process_running(proc) || break
                sleep(0.1)
            end
            process_running(proc) && kill(proc, Base.SIGKILL)
            break
        end
        sleep(0.2)
    end
    wait(proc)
    text = fetch(reader)
    seconds = time() - started
    marker = findlast("FUZZRESULT ", text)
    if timed_out
        return FuzzResult(seed, false, true, seconds, string("did not finish in ", round(Int, limit), " s (`FUZZ_TIME_LIMIT`)", "\n", last(text, min(length(text), 600))))
    elseif marker === nothing
        return FuzzResult(seed, false, false, seconds, string("the process ended (", proc.exitcode, ") without a result\n", last(text, min(length(text), 1500))))
    end
    verdict = text[last(marker)+1:end]
    ok = startswith(verdict, "ok")
    nl = findfirst('\n', verdict)
    return FuzzResult(seed, ok, false, seconds, ok || nl === nothing ? "" : strip(verdict[nl+1:end]))
end

# The cases of `seeds`, `workers` at a time, in the order of the seeds
function run_fuzz_cases(kind::AbstractString, seeds::Vector{UInt})
    results = Vector{FuzzResult}(undef, length(seeds))
    next = Threads.Atomic{Int}(1)
    @sync for _ in 1:min(fuzz_workers(), length(seeds))
        @async while true
            i = Threads.atomic_add!(next, 1)
            i > length(seeds) && break
            results[i] = run_fuzz_case(kind, seeds[i])
        end
    end
    return results
end

# The seeds for a kind: those that are given, or the pinned ones (the seeds that failed once: `pinned.jl`) and random ones
function fuzz_seeds(kind::AbstractString, pinned::Vector{UInt})
    given = get(ENV, "FUZZ_SEEDS", "")
    isempty(given) || return parse_fuzz_seeds(given)
    count = parse(Int, get(ENV, "FUZZ_COUNT", "20"))
    return unique!(vcat(pinned, rand(UInt, count)))
end

# The testset of a kind: a test for each seed. Nothing is written for the seeds that pass.
function fuzz_testset(kind::AbstractString, name::AbstractString, pinned::Vector{UInt})
    seeds = fuzz_seeds(kind, pinned)
    results = run_fuzz_cases(kind, seeds)
    @testset "$name" begin
        for r in results
            if r.ok
                @test true
            else
                @info string("fuzz: ", kind, " ", hexseed(r.seed), r.timed_out ? " did not finish" : " failed", "\nrun it again with: ", fuzz_repro_command(kind, r.seed), "\n", r.detail)
                @test false
            end
        end
        slowest = maximum(r -> r.seconds, results; init = 0.0)
        isempty(get(ENV, "FUZZ_VERBOSE", "")) || @info string(kind, ": ", length(results), " cases, the slowest ", round(slowest; digits = 1), " s")
    end
    return nothing
end
