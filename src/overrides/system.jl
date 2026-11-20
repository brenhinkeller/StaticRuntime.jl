# Overrides for the system: time, `sleep`, locks, exit and `atexit`, the paths of libraries, `OncePerProcess`, signals,
# and deprecation warnings.

# `sleep` is a timer of libuv, which needs the event loop. Here it is the tasks that are scheduled, run, and then
# `nanosleep` (started again with the time that is left if a signal interrupts it)
@device_override function Base.sleep(sec::Real)
    sec >= 0 || throw(ArgumentError("sleep time must be nonnegative, got $sec"))
    isnan(sec) && throw(ArgumentError("sleep time must not be NaN"))
    yield() # (the tasks that are scheduled run while the program sleeps: see `tasks.jl`)
    whole = floor(min(Float64(sec), 1e15))
    nanos = round(Int64, (min(Float64(sec), 1e15) - whole) * 1e9)
    whole_s = Int64(whole)
    nanos >= 1_000_000_000 && (whole_s += 1; nanos -= 1_000_000_000)
    request = Ref((whole_s, nanos))
    left = Ref((Int64(0), Int64(0)))
    while ccall(:nanosleep, Cint, (Ref{NTuple{2,Int64}}, Ref{NTuple{2,Int64}}), request, left) != 0
        request[] = left[]
    end
    return nothing
end

# Locks. A compiled program has one thread and no tasks, so a lock can never be contended: taking
# one has no effect. (Without this, `lock` pulls in the whole task scheduler, for the case in
# which another task holds the lock.) Note that unlocking a lock that is not held is not an error.
@device_override Base.lock(::ReentrantLock) = nothing

@device_override Base.unlock(::ReentrantLock) = nothing

@device_override Base.trylock(::ReentrantLock) = true

@device_override Base.islocked(::ReentrantLock) = false

# The clocks of libc (`jl_hrtime` and `jl_clock_now` are libjulia's, which is not there)
function clock_nanoseconds(id::Int32)
    ts = Ref((Int64(0), Int64(0))) # `struct timespec`: seconds and nanoseconds
    GC.@preserve ts begin
        @symbolcall clock_gettime(id::Int32, Base.unsafe_convert(Ptr{NTuple{2,Int64}}, ts)::Ptr{NTuple{2,Int64}})::Int32
    end
    sec, nsec = ts[]
    return UInt64(sec) * UInt64(1_000_000_000) + UInt64(nsec)
end

const CLOCK_REALTIME = Int32(0)

const CLOCK_MONOTONIC = Sys.isapple() ? Int32(6) : Int32(1)

@device_override Base.time_ns() = clock_nanoseconds(CLOCK_MONOTONIC)

@device_override Base.time() = clock_nanoseconds(CLOCK_REALTIME) / 1e9

# There is one thread
@device_override Base.Threads.nthreads() = 1

# The time of day: `jl_gettimeofday` is a function of libjulia; `gettimeofday` is that of the C library (so
# `Dates.now()` and `today()` work: the zone is that of the machine that runs the program, from `localtime_r`)
@device_override function Base.Libc.TimeVal()
    tv = Ref{Base.Libc.TimeVal}()
    status = ccall(:gettimeofday, Cint, (Ref{Base.Libc.TimeVal}, Ptr{Cvoid}), tv, C_NULL)
    status != 0 && error("unable to determine current time: ", status)
    return tv[]
end

# `disable_sigint(f)` (HiGHS calls its solver in it) defers what Julia does on a SIGINT (an `InterruptException`) with a
# count in the state of the thread, which a program does not have: a program has no handler that turns a SIGINT into an
# exception (it is ended by it, as a C program is), so there is nothing to defer
@device_override Base.sigatomic_begin() = nothing

@device_override Base.sigatomic_end() = nothing

# Deprecation warnings (`Base.depwarn`, which packages call from the methods that are deprecated) look at the options of
# the Julia that runs (`JLOptions()`, `--depwarn`), which a program does not have; and are not shown by default: nothing
# is done
@device_override Base.depwarn(msg, funcsym; force::Bool = false) = nothing

@device_override Base.depwarn_if_not_pure(args...) = nothing # (the deprecated properties of types, `Type.name`, which `@deprecate` reads)

# `exit(code)` ends the program with the status `code`, through the C library (which runs the functions of `atexit` and
# flushes the streams); Julia's tells the runtime, and runs them itself
@device_override Base.exit(code::Integer) = ccall(:exit, Union{}, (Cint,), Cint(code))

@device_override Base.exit() = ccall(:exit, Union{}, (Cint,), Cint(0))

# `atexit(f)`: the functions are run when the program ends, last registered first, as in Julia. The first `atexit` of
# the program registers one function of the C library (`atexit`), which runs them: it is run by the C library when
# `main` returns and when `exit` is called, whatever the entry point is, and before the streams are flushed. (The
# functions that the standard libraries register, SuiteSparse's, which shuts it down, which the system does by ending
# the process, are not kept.) An error in one of them does not stop the others. The functions are called by
# `call_callback`: they are the ones that were registered.
struct AtExit end

const ATEXIT_HOOKS = Any[]

const ATEXIT_INSTALLED = Ref(false)

function run_atexit_hooks()
    while !isempty(ATEXIT_HOOKS)
        f = pop!(ATEXIT_HOOKS)
        try
            call_callback(AtExit, f)
        catch
        end
    end
    return nothing
end

@noinline function install_atexit_runner()
    ATEXIT_INSTALLED[] && return nothing
    ATEXIT_INSTALLED[] = true
    ccall(:atexit, Cint, (Ptr{Cvoid},), @cfunction(run_atexit_hooks, Cvoid, ()))
    return nothing
end

@generated function static_atexit(f::F) where {F}
    parent = parentmodule(F)
    standard = parent in (Base, Core) || nameof(parent) in (:LibSuiteSparse, :SparseArrays, :CHOLMOD, :UMFPACK, :SPQR)
    return standard ? :(nothing) : quote
        note_callback(AtExit, f)
        push!(ATEXIT_HOOKS, f)
        install_atexit_runner()
        return nothing
    end
end

@device_override Base.atexit(f::Function) = static_atexit(f)

# the path of a `LazyLibrary`, as the compiler has it (see `host_dlpath` in `runtime/libraries.jl`)
@device_override Runtime.Libdl.dlpath(lib::Runtime.Libdl.LazyLibrary) = Runtime.host_dlpath(lib)

# `OncePerProcess` (what a library has to set itself up the first time that it is used: SuiteSparse, ...): Base's takes
# a lock and tells the system of packages that the value is made (`jl_set_precompile_field_replace`, `__precompile__`),
# neither of which there is in a program that is compiled, which has one task. The embedded object starts as one that
# has not run (see `field_cut` in `runtime/objects.jl`).
@device_override @inline function (once::Base.OncePerProcess{T,F})() where {T,F}
    if (@atomic once.state) != 0x01
        once.value = once.initializer()
        @atomic once.state = 0x01
    end
    return once.value::T
end

# The entropy of the system: `Random.RandomDevice` (and with it `uuid4()`) reads the entropy of the system with `Libc.getrandom!`, which is libuv's
# `uv_random`. `getentropy` gives at most 256 bytes at a call.
@device_override function Libc.getrandom!(A::Union{Array,Base.RefValue})
    p = Ptr{UInt8}(pointer_from_objref(A))
    A isa Array && (p = Ptr{UInt8}(pointer(A)))
    n = sizeof(A)
    GC.@preserve A while n > 0
        m = min(n, 256)
        ok = @symbolcall getentropy(p::Ptr{UInt8}, UInt(m)::UInt)::Int32
        ok == 0 || error("could not get entropy from the system")
        p += m
        n -= m
    end
    return A
end
