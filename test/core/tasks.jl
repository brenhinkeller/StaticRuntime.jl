# Tasks that run to completion (`src/overrides/tasks.jl`): `@async`, `Threads.@spawn`, `Task`, `schedule`, `wait`, `fetch`, `yield`, `Condition`, `Channel`, `@sync`; what is kept for the task that runs (`current_task`,
# `task_local_storage`, `ScopedValue`s), and what the program runs when it ends (`atexit`). The tasks run when something waits, one after another, each to its end, as they would on one thread.

using Base.ScopedValues

const TSV = ScopedValue(1)
const TCOND = Condition()

task_cases() = [
    "@async and fetch"            => () -> fetch(@async opaque(1) + 1),
    "Threads.@spawn and fetch"    => () -> fetch(Threads.@spawn opaque(1) + 2),
    "Task, schedule and wait"     => () -> (t = Task(() -> opaque(2)); schedule(t); wait(t); fetch(t)),
    "a task that fails"           => () -> (t = @async error("failed"); try; fetch(t); 0; catch e; e isa TaskFailedException ? opaque(1) : 2; end),
    "the tasks run when the program waits, in order" => () -> (log = Int[]; a = @async push!(log, opaque(1)); b = @async push!(log, 2); push!(log, 0); wait(a); wait(b); log[1] * 100 + log[2] * 10 + log[3]),
    "yield lets a task run"       => () -> (r = Ref(0); @async r[] = opaque(5); yield(); r[]),
    "a task that waits for another" => () -> (b = @async opaque(3); a = @async fetch(b) + 1; fetch(a)),
    "@sync"                       => () -> (r = Ref(0); @sync begin; @async r[] += opaque(1); @async r[] += 10; end; r[]),
    "a Condition"                 => () -> (r = Ref(0); @async (r[] = opaque(4); notify(TCOND)); wait(TCOND); r[]),
    "a Channel"                   => () -> (c = Channel{Int}(2); put!(c, opaque(1)); put!(c, 2); take!(c) + take!(c)),
    "a Channel that a task fills" => () -> (c = Channel{Int}(4) do ch; for i in 1:3; put!(ch, i + opaque(0)); end; end; sum(c)),
    "a Channel with no buffer"    => () -> (c = Channel{Int}(0) do ch; for i in 1:3; put!(ch, i + opaque(0)); end; end; s = 0; for x in c; s += x; end; s),
    "tasks that put and take"     => () -> (c = Channel{Int}(1); p = @async (for i in 1:4; put!(c, i + opaque(0)); end; close(c)); s = 0; for x in c; s += x; end; wait(p); s),
    "current_task"                => () -> (current_task() === current_task() && current_task() isa Task ? opaque(1) : 0),
    "task_local_storage"          => () -> (task_local_storage(:k, opaque(3)); a = task_local_storage(:k)::Int; b = fetch(@async (task_local_storage(:k, 5); task_local_storage(:k)::Int)); a * 10 + b),
    "the task of a task"          => () -> (t = @async current_task(); fetch(t) === t ? opaque(1) : 0),
    "a ScopedValue"               => () -> TSV[] + opaque(0),
    "with ends"                   => () -> (a = @with(TSV => opaque(2), TSV[]); b = TSV[]; a * 10 + b),
    "with nested"                 => () -> (@with(TSV => opaque(2), (@with(TSV => 3, TSV[]) * 10 + TSV[])) * 10 + TSV[]),
    "with after an error"         => () -> (try; @with(TSV => opaque(9), error("x")); catch; end; TSV[]),
    "a task has the scope that made it" => () -> @with(TSV => opaque(7), fetch(@async TSV[])),
    "setprecision of BigFloat"    => () -> (setprecision(BigFloat, 100) do; Int(round(big(2)^70 / big(3)^10)) % 1000; end),
]

@testset "Tasks and scoped values" begin
    check_cases(task_cases(); batch = false)
end

# what is run when the program ends: the functions of `atexit`, last registered first, by the C library, so for `exit` as well as for the end of `main`, and before the streams are flushed
@eval at_exit_order(argc::Int, argv::Ptr{Ptr{UInt8}}) = (atexit(() -> println("first")); atexit(() -> println("second")); println("main"); 0)
@eval at_exit_state(argc::Int, argv::Ptr{Ptr{UInt8}}) = (x = argc + 6; atexit(() -> println("x = ", x)); println("end"); 0)
@eval at_exit_exit(argc::Int, argv::Ptr{Ptr{UInt8}}) = (atexit(() -> println("hook")); argc < 100 && exit(0); println("not reached"); 0)
@eval at_exit_error(argc::Int, argv::Ptr{Ptr{UInt8}}) = (atexit(() -> println("after the one that fails")); atexit(() -> error("a hook that fails")); println("main"); 0)
@eval at_exit_task(argc::Int, argv::Ptr{Ptr{UInt8}}) = (atexit(() -> println("task: ", fetch(@async 42))); println("main"); 0)

@testset "`atexit`" begin
    @test run_main(at_exit_order) == "main\nsecond\nfirst"
    @test run_main(at_exit_state) == "end\nx = 7"
    @test run_main(at_exit_exit) == "hook"
    @test run_main(at_exit_error) == "main\nafter the one that fails"
    @test run_main(at_exit_task) == "main\ntask: 42"
end

# a program in which nothing can go on stops with a message that says so (in Julia it would wait for ever)
@eval task_deadlock(argc::Int, argv::Ptr{Ptr{UInt8}}) = (c = Channel{Int}(1); println(take!(c)); 0)
@testset "A deadlock is an error" begin
    code, err = run_main_failing(task_deadlock)
    @test code != 0
    @test occursin("deadlock: every task waits for something that no task gives", err)
end
