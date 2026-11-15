# What the manual says does not work, and what happens then: the program is refused when compiling, with a message that says why; or it compiles, and says so when it is run; or it does
# not do what Julia does, in the way that the manual says. A test here fails when one of them changes, in either direction: if something starts to work, move its case to the tests of the
# part of the language or of the library that it belongs to, and change the manual (the section "Known limitations"); if something that was refused now compiles and does not work, that is
# worse than the refusal.

# (this file has a budget of two minutes. `static_status` does not compile a refusal a second time for the places in the code (`strip = true`), and the two programs that reach so much of Base that they take about a
# minute to compile (starting another program, `Markdown.parse`) are compiled by processes of their own, which run while the rest of the file does; the last test says if the budget was not kept)
const LIMITATIONS_START = time()

# the refusal of the program `code` (the source of a function of no arguments) by a process of its own that is started now: `(process, file)`, to be read by `refusal_of`
function refusal_in_process(code::AbstractString)
    file = tempname()
    script = """
        using Test, Random, Printf, Libdl, Markdown
        include($(repr(joinpath(@__DIR__, "..", "helpers.jl"))))
        status, detail = static_status($code; strip = true)
        write($(repr(file)), string(status, '\\n', detail))
        """
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) -e $script`
    return run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull); wait = false), file
end
# (it is waited for no longer than what is left of the budget: a process that does not end is a failure, and is stopped)
function refusal_of((proc, file))
    timedwait(() -> !process_running(proc), max(10.0, 110 - (time() - LIMITATIONS_START))) === :ok || (kill(proc); return :timeout, "the process did not end in time")
    isfile(file) || return :no_answer, "the process ended without an answer"
    status, detail = split(read(file, String), '\n'; limit = 2)
    return Symbol(status), String(detail)
end
const WORKERS = Dict(
    "starting another program" => refusal_in_process("() -> (run(`true`); 0)"),
    "Markdown.parse"           => refusal_in_process("() -> length(string(Markdown.parse(opaque(\"# a\"))))"),
)

# a tuple that has a `Union` as an element, and that is not removed by inlining (here it is returned by a function that is not inlined): it is made with the types that its values have when the
# program runs, which an executable can't make. (When the function is inlined the tuple is not made: see `inline_tupleret_bonus` in `src/inference/dispatch.jl`.)
@noinline union_tuple(n::Int) = (n > 0 ? [1.0] : [1.0im], n)

@noinline recurse_forever(n::Int) = n == 0 ? 0 : 1 + recurse_forever(n - 1)
@noinline function nested_try(n::Int, v::Vector{Int}) # (the recursion is not a loop that the compiler can make: a value is kept after each call)
    n == 0 && return 0
    try
        r = nested_try(n - 1, v)
        push!(v, r)
        return r + 1
    catch
        return -1
    end
end

# what is said when a program is refused: it names the runtime that it needs, or the objects that it refers to by address, or the type that it does not infer
const REFUSAL = r"Julia runtime|by their address|does not infer to a concrete type"

@testset "Refused when compiling" begin
    cases = [
        # a tuple that has an element of a `Union` of types, and is made when the program runs
        "a tuple with a Union element, not inlined" => () -> (p = union_tuple(opaque(1)); p[2] * 10 + length(p[1])),
        # code that is made when the program runs
        "eval"                        => () -> Core.eval(Main, :(1 + 1)),
        # functions of the libraries that Julia has (utf8proc) and does not have as libraries of their own
        "Unicode.normalize"           => () -> length(Unicode.normalize(opaque("é"))),
        "graphemes"                   => () -> length(collect(graphemes(opaque("ab")))),
        "titlecase of a string"       => () -> length(titlecase(opaque("hello world"))),
        # the system, and the state of the compiling Julia
        "@time"                       => () -> (@time opaque(1) + 1; 0),
        "TOML.parse"                  => () -> length(TOML.parse(opaque("a = 1"))),
    ]
    for (name, f) in cases
        @testset "$name" begin
            status, detail = static_status(f; strip = true) # (the refusal is not compiled a second time, with the debug information that says where in the code: the message is what is checked)
            @test status == :compile_error
            @test occursin(REFUSAL, string(detail))
        end
    end
end

# Starting another program: `run`, and the types of the processes of libuv, are refused when compiling (compiled by a process of its own: see above)
@testset "Starting another program" begin
    status, detail = refusal_of(WORKERS["starting another program"])
    @test status == :compile_error
    @test occursin(REFUSAL, detail)
end

# `Markdown.parse` is a parser that is a list of functions, for blocks and for text in a line, and the parser of the Julia language for the code and the `$` that it finds: the list of functions is not found by the registry of closures, and Julia's parser is in
# libjulia. It is refused when compiling, or (when what the slots hold lets the calls on it be compiled) the program stops when it gets there, with a message: either way it does not give a wrong answer
@testset "Markdown.parse" begin
    status, detail = refusal_of(WORKERS["Markdown.parse"])
    @test status in (:compile_error, :runtime_error)
end

# what a program does that is not what Julia does, as the manual says (the section "Differences from Julia when the program runs")
@testset "Differences from Julia" begin
    @testset "locks do nothing: `islocked` is false" begin
        f = () -> (l = ReentrantLock(); lock(l); r = islocked(l); unlock(l); Int(r))
        @test static_status(f)[1] == :mismatch
    end
    @testset "no check of the size of the stack: infinite recursion is a crash, not a StackOverflowError" begin
        exe = compile_main(() -> recurse_forever(opaque(100_000_000)))
        p = run(pipeline(ignorestatus(`$exe`); stdout = devnull, stderr = devnull))
        @test !success(p)
        @test p.termsignal != 0 # (a segmentation fault, not an exit with a message)
    end
    @testset "at most 256 `try` blocks are active at once" begin
        run_nested(n) = (exe = compile_main(() -> (v = Int[]; nested_try(opaque(n), v) + length(v)));
                         out = IOBuffer(); p = run(pipeline(ignorestatus(`$exe`); stdout = out, stderr = out)); (p.exitcode, String(take!(out))))
        code, output = run_nested(100)
        @test code == 0
        code, output = run_nested(300)
        @test code != 0
        @test occursin("exception handler stack overflow", output)
    end
end

@testset "The time that this file takes" begin
    @test time() - LIMITATIONS_START < 120
end
