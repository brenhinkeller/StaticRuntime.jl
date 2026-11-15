# Tasks that run to completion: `@async`, `Threads.@spawn`, `Task`, `schedule`, `wait`, `fetch`, `yield`, `sleep`, `Condition` and `Channel` in a program that has one thread and one stack.
#
# A `Task` is an object like any other here (made by `make_task`: its `code` is the function that it runs), and `current_task()` is the one that is running (the main one, made when it is first asked
# for, is a `Task` that has no code). A task that is scheduled (`schedule`, `@async`, `Threads.@spawn`: `enq_work`) waits in a queue. What blocks, `wait()` of Julia, which is what `wait(task)`,
# `wait(condition)`, `take!` of a channel, `fetch`, `yield` and `sleep` are made of, does here what the scheduler would have done: it runs the tasks of the queue, one after another and each to its end, on the
# stack of the task that waits, until the task that waits is scheduled again (a `notify` of the condition that it waits for, or the end of the task that it waits for). A task that is run in that way and
# waits itself runs the others in the same way, on top of the first. So:
#
# * the tasks run when something waits (as in Julia, where a task that is scheduled runs when the one that made it waits or yields), in the order that they were scheduled;
# * a task goes on after it waits when the ones that it ran have returned, so a program in which the tasks wait for each other in the order that they were started (a producer, a consumer; a
#   `@sync` of tasks that finish, a `Channel` that tasks put into and the program takes from) is what runs here; one that needs a task to be resumed that is lower on the stack than the one that is
#   running (two tasks that hand a value to each other many times) stops with a message that says so, as does one in which every task waits for something that none of them gives (a deadlock).
#
# (`Task` has fields for what Julia's scheduler keeps in them: `last_started_running_at` says that it was started, here, and `sticky` that it was woken by a `schedule` while it waited.)

const RUNQUEUE = Task[]
const CURRENT_TASK = Ref{Union{Nothing,Task}}(nothing)

# a `Task` of the function `f` that runs in the scope `scope` (`new` of `Task` is refused, as it has fields of the runtime of Julia: the object is made zero, by the runtime of this package, and given the fields that it has)
function make_task(f, scope, donenotify)
    t = ccall(:static_new_task, Any, (Int,), sizeof(Task))::Task
    setfield!(t, :next, nothing)
    setfield!(t, :queue, nothing)
    setfield!(t, :storage, nothing)
    setfield!(t, :donenotify, donenotify)
    setfield!(t, :result, nothing)
    setfield!(t, :scope, scope)
    setfield!(t, :code, f)
    setfield!(t, :invoked, nothing)
    return t
end

@noinline function main_task()
    t = make_task(nothing, nothing, Base.ThreadSynchronizer())
    set_started!(t)
    CURRENT_TASK[] = t
    return t
end

@device_override Base.current_task() = (t = CURRENT_TASK[]; t === nothing ? main_task() : t)

@device_override function Core.Task(f, reserved_stack::Int)
    note_callback(Tuple{}, f)
    return make_task(f, Core.current_scope(), Base.ThreadSynchronizer())
end
@device_override Core.Task(f) = Core.Task(f, 0)

# (the fields of the state of a task are atomic)
task_state(t::Task) = @atomic :acquire t._state
set_state!(t::Task, state::UInt8) = (@atomic :release t._state = state; nothing)
task_started(t::Task) = (@atomic :acquire t.last_started_running_at) != UInt64(0)
set_started!(t::Task) = (@atomic :release t.last_started_running_at = UInt64(1); nothing)

@device_override Base.istaskstarted(t::Task) = task_started(t)

# (the thread pool of a task made by `Threads.@spawn`)
@device_override Base.Threads._spawn_set_thrpool(t::Task, tp::Symbol) = nothing

# scheduling: the task waits in the queue; one that is woken is the one that waits in `wait()` below
@device_override function Base.enq_work(t::Task)
    (task_state(t) === 0x00) || error("schedule: Task not runnable")
    push!(RUNQUEUE, t)
    return t
end

function finish_task!(t::Task)
    donenotify = t.donenotify
    if donenotify isa Base.ThreadSynchronizer
        lock(donenotify)
        try
            notify(donenotify)
        finally
            unlock(donenotify)
        end
    end
    return nothing
end

# the code of a task, run now (to its end) as the current task, in the scope that it was made in
function run_task!(t::Task)
    previous = current_task()
    CURRENT_TASK[] = t
    set_started!(t)
    try
        result = Base.ScopedValues.@enter_scope getfield(t, :scope) call_callback(Tuple{}, getfield(t, :code))
        setfield!(t, :result, result)
        set_state!(t, 0x01)
    catch err
        setfield!(t, :result, err)
        setfield!(t, :_isexception, true)
        set_state!(t, 0x02)
    end
    CURRENT_TASK[] = previous
    finish_task!(t)
    return nothing
end

# `wait()`: the task that calls it is not run again until something schedules it. Here the tasks that are scheduled are run, in order, until it is one of them: the value that it was scheduled with is what `wait` gives
# (or the error, if it was scheduled with one)
@device_override function Base.wait()
    me = current_task()
    skipped = 0
    while true
        isempty(RUNQUEUE) && error("deadlock: every task waits for something that no task gives (the tasks of a program run one at a time, each to its end)")
        t = popfirst!(RUNQUEUE)
        if t === me
            result = getfield(me, :result)
            setfield!(me, :result, nothing)
            if getfield(me, :_isexception)
                setfield!(me, :_isexception, false)
                throw(result)
            end
            return result
        elseif task_state(t) !== 0x00
            continue # (it has finished: it was scheduled twice)
        elseif !task_started(t)
            skipped = 0
            run_task!(t)
        else
            # a task that waits lower on the stack was woken: it goes on when the tasks above it have returned
            push!(RUNQUEUE, t)
            skipped += 1
            skipped > length(RUNQUEUE) && error("a task that waits was woken, but it is lower on the stack than the one that is running, and goes on only when this one returns: the tasks of a program run one at a time, each to its end")
        end
    end
end

@device_override function Base.yield()
    Base.enq_work(current_task())
    wait()
    return nothing
end

# `yield(t)`: `t` runs first
@device_override function Base.yield(t::Task, @nospecialize(x = nothing))
    (task_state(t) === 0x00) || error("yield: Task not runnable")
    pushfirst!(RUNQUEUE, t)
    setfield!(t, :result, x)
    yield()
    return nothing
end
@device_override Base.yieldto(t::Task, @nospecialize(x = nothing)) = (yield(t, x); nothing)

# (what a lock does here is nothing, as `lock` of a `ReentrantLock` does: see `base.jl`; a condition that waits has to give its lock up and take it again)
@device_override Base.unlockall(::ReentrantLock) = 1
@device_override Base.relockall(::ReentrantLock, n::Int) = nothing
@device_override Base.assert_havelock(::ReentrantLock) = nothing

# (nothing watches a task that is not waited for: Julia prints the error of a task that failed, which it does when the task ends)
@device_override Base.errormonitor(t::Task) = t

# (there is one thread, and a task is on it: the code of Base that sticks a task to the thread of the task that made it is not reached, and is not compiled)
@device_override Base.Threads.threadid(::Task) = 1
@device_override Base.GC.in_finalizer() = false

# (a spin lock is never contended: it does nothing, as `lock` of a `ReentrantLock` does; Base's disables the finalizers, with a field of the thread that the tasks here do not have)
@device_override Base.lock(::Base.Threads.SpinLock) = nothing
@device_override Base.unlock(::Base.Threads.SpinLock) = nothing
@device_override Base.trylock(::Base.Threads.SpinLock) = true
@device_override Base.islocked(::Base.Threads.SpinLock) = false
@device_override Base.assert_havelock(::Base.Threads.SpinLock) = nothing
@device_override Base.GC.disable_finalizers() = nothing
@device_override Base.GC.enable_finalizers() = nothing

# the end of a `@sync`: the tasks that were made in it are waited for (a `Channel{Any}` of what was scheduled; only tasks are here), and those that failed are the exceptions of a `CompositeException`
@device_override function Base.sync_end(c::Channel{Any})
    exceptions = Any[]
    while isready(c)
        r = take!(c)
        if r isa Task
            Base._wait(r)
            istaskfailed(r) && push!(exceptions, TaskFailedException(r))
        else
            error("`@sync` waits for tasks: what else it can wait for is not supported in compiled programs")
        end
    end
    close(c)
    isempty(exceptions) || throw(CompositeException(exceptions))
    return nothing
end

# `Channel`: a task that puts into a channel runs to its end before the one that takes from it goes on (the one that takes is lower on the stack, and can't be resumed before), so `put!` does not wait for room
# or for a task that takes: the channel holds what is put in it, however much, and `take!` waits (for a task that puts, and runs). What is put is taken in the same order, and what a program prints is as it is
# if the tasks print only where they take or where they put, and not both.
@device_override function Base.put_buffered(c::Channel, v)
    Base.check_channel_state(c)
    Base._increment_n_avail(c, 1) # (the number that `isready` looks at)
    push!(c.data, v)
    notify(c.cond_take, nothing, true, false)
    c.cond_wait === c.cond_take || notify(c.cond_wait, nothing, true, false) # (a channel with no buffer has a condition of its own for `wait(c)`)
    return v
end
@device_override Base.put_unbuffered(c::Channel, v) = Base.put_buffered(c, v)

@device_override function Base.take_unbuffered(c::Channel{T}) where {T}
    while isempty(c.data)
        Base.check_channel_state(c)
        wait(c.cond_take)
    end
    v = popfirst!(c.data)
    Base._increment_n_avail(c, -1)
    return v::T
end

# The scope of a task is a `PersistentDict` of the `ScopedValue`s (of different types: the key is an `AbstractScopedValue`) that are set in it, which hashes the key by `objectid`; a value of the type that is
# not known is not looked up in the methods of `objectid` (it is a call of the runtime): the scoped values are mutable, and the number of an object that is mutable is its address
static_objectid(x::Base.ScopedValues.AbstractScopedValue) = int64hash(UInt64(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x))))
