# `throw`, `try`, `catch`, `finally`, `rethrow`, and the errors of Base: what a compiled program catches and when it runs `finally`, compared with Julia. The values that decide what is thrown are `opaque` (see `helpers.jl`): with constants, the compiler would run the exceptions itself, and the program would only print the answer.

@noinline thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
@noinline thrower3(x::Int) = x == 1 ? throw(ArgumentError("a")) : x == 2 ? throw(DomainError(x, "b")) : [1, 2, 3][x + 10]
@noinline thrower2(x::Int) = x == 1 ? throw(ArgumentError("a")) : throw(DomainError(x, "b"))
@noinline deep(n::Int) = n == 0 ? thrower(1) : [n; deep(n - 1)...][1] # allocates on the way

@testset "Exceptions" begin
    check_cases([
    "try/catch"             => () -> (try; thrower(opaque(1)); catch; 7; end),
    "try no throw"          => () -> (try; thrower(opaque(0)); catch; 7; end),
    "try/finally"           => () -> (r = Ref(opaque(0)); try; r[] += 1; finally; r[] += 10; end; r[]),
    "catch and finally"     => () -> (r = Ref(0); try; try; thrower(opaque(1)); finally; r[] += 10; end; catch; r[] += 1; end; r[]),
    "rethrow"               => () -> (try; try; thrower(opaque(1)); catch; rethrow(); end; catch; 5; end),
    "nested try"            => () -> (try; try; thrower(opaque(1)); catch; thrower(opaque(2)); end; catch; 9; end),
    "throw through frames"  => () -> (try; deep(opaque(5)); catch; -1; end),
    "catch in loop"         => () -> (s = 0; for i in 1:5; try; thrower(opaque(i % 2)); catch; s += i; end; end; s),
    "catch typed 3 types"   => () -> (s = 0; for i in 1:3; s += try; thrower3(opaque(i)); 0; catch e; e isa ArgumentError ? 1 : e isa DomainError ? 10 : e isa BoundsError ? 100 : 1000; end; end; s),
    "catch typed"           => () -> (try; thrower2(opaque(2)); catch e; e isa DomainError ? 2 : 1; end),
    "BoundsError caught"    => () -> (try; [1, 2, 3][opaque(5)::Int]; catch; 3; end),
    "InexactError caught"   => () -> (try; Int8(opaque(300)::Int); catch; 4; end),
    "DivideError caught"    => () -> (try; div(1, opaque(0)::Int); catch; 5; end),
    "error() caught"        => () -> (try; opaque(1) > 0 && error("x"); 0; catch; 7; end),
    "throw caught"          => () -> (try; opaque(1) > 0 && throw(ArgumentError("x")); 2; catch e; e isa ArgumentError ? 1 : 0; end),
    ])
end

# no handler: the program reports the exception and exits with a failure status, rather than crashing
@testset "An exception that is not caught" begin
    @eval @noinline rt_thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
    @eval rt_uncaught(argc::Int, argv::Ptr{Ptr{UInt8}}) = (rt_thrower(argc); 0)
    exe = compile_executable(rt_uncaught, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "rt_uncaught")
    p = run(ignorestatus(pipeline(`$exe`; stderr = devnull, stdout = devnull)))
    @test p.exitcode == 1
end

# `@assert` with a message that is not a literal: a `String`, shown by the program when the assertion fails
assert_message(n::Int) = (@assert n > 0 "n = $n is not positive"; n + 1)
@testset "@assert with a message" begin
    @test static_result(() -> assert_message(opaque(3))) == 4
    main = StaticRuntime.make_main(() -> (try; assert_message(opaque(-5)); catch e; e isa AssertionError ? length(e.msg) : -1; end))
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
    @test parse(Int, readchomp(`$exe`)) == length("n = -5 is not positive")
end

# A call that has no method for what reaches it (a constructor with no method for an argument that the code can have, here) says which one it was
mutable struct NoMethodFor; name::String; NoMethodFor(name::String) = new(name); end
@testset "A call with no method names the function or the type" begin
    @eval @noinline rt_calls_constructor(x) = NoMethodFor(x)
    @eval rt_no_method(argc::Int, argv::Ptr{Ptr{UInt8}}) = (rt_calls_constructor(time_ns() >> 63 == 0 ? 5 : "s"); 0)
    exe = compile_executable(rt_no_method, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "rt_no_method")
    err = tempname()
    p = run(ignorestatus(pipeline(`$exe`; stderr = err, stdout = err)))
    @test p.exitcode != 0
    @test occursin("no method matching `NoMethodFor`", read(err, String)) && !occursin("add_dispatch_candidates", read(err, String))
end


# An exception that nothing catches says what it was, on the standard error (the type, and the message where the first field of it is
# a string); what the program wrote to the standard output is only what it wrote
struct RtMessageError <: Exception; msg::String; end
struct RtCodeError <: Exception; code::Int; end
@noinline rt_fail(k::Int) = k == 1 ? throw(ArgumentError("bad argument 7")) :
                            k == 2 ? error("plain text") :
                            k == 3 ? throw(RtMessageError("custom message")) :
                            k == 4 ? throw(RtCodeError(42)) :
                            k == 5 ? (@assert k > 9 "k is too small") :
                            k == 6 ? [1, 2][k] :
                            k == 7 ? throw("a thrown string") :
                            0
@eval rt_fail_main(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println("before"); rt_fail(argc - 1); println("after"); 0)
@testset "An exception that is not caught says what it was" begin
    exe = compile_executable(rt_fail_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "rt_fail_main")
    expected = ["ERROR: ArgumentError: bad argument 7", "ERROR: ErrorException: plain text", "ERROR: RtMessageError: custom message",
                "ERROR: RtCodeError", "ERROR: AssertionError: k is too small", "ERROR: BoundsError", "ERROR: a thrown string"]
    for (k, text) in enumerate(expected)
        out, err = tempname(), tempname()
        p = run(ignorestatus(pipeline(Cmd(`$exe $(fill("x", k))`); stdout = out, stderr = err)))
        @test p.exitcode == 1
        @test read(out, String) == "before\n"
        @test read(err, String) == text * "\n"
    end
    # (a program that does not throw is the same as it was: nothing on the standard error)
    out, err = tempname(), tempname()
    p = run(ignorestatus(pipeline(`$exe $(fill("x", 8))`; stdout = out, stderr = err)))
    @test p.exitcode == 0 && read(out, String) == "before\nafter\n" && isempty(read(err, String))
end

# A caught exception (`catch e`) is a value of the type `Any`, and a call on it is made over the registered types, the exceptions of the program's own, and the common ones of Base that the code throws:
# `showerror(io, e)` of an `ArgumentError` or an `ErrorException` gives Julia's text
@testset "showerror of a caught exception" begin
    @eval @noinline caught_argument(s::String) = try; parse(Int, s); 0; catch e; showerror(STDERR, e); println(STDERR); 1; end
    @eval caught_main(argc::Int, argv::Ptr{Ptr{UInt8}}) = caught_argument(opaque(1) == 1 ? "x" : "1") + (try; error("boom ", opaque(2)); 0; catch e; showerror(STDERR, e); println(STDERR); 0; end)
    code, err = run_main_failing(caught_main)
    expected = try parse(Int, "x") catch e; sprint(showerror, e) end * "\n" * sprint(showerror, ErrorException("boom 2")) * "\n"
    @test err == expected
    @test code == 1
end
