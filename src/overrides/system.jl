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

@inline clock_monotonic() = target_choice(Int32(6), Int32(1))

@device_override Base.time_ns() = clock_nanoseconds(clock_monotonic())

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

# `@time`, `@timed` and `@timev` (and `time_print`): the time is measured, and what Julia counts of the collector and the
# compiler is not: the heap does not count the bytes of each allocation, and nothing is compiled when the program runs. So
# the counters are zero, and `@time` writes only the seconds (`  0.000012 seconds`), and `@timed` has `bytes = 0`,
# `gctime = 0`, `compile_time = 0`. (`@allocated` needs the bytes, and is not supported; `@allocations` is -1.)
@generated zero_gc_num() = Expr(:call, Base.GC_Num, (:(zero($(fieldtype(Base.GC_Num, i)))) for i in 1:fieldcount(Base.GC_Num))...)
@device_override Base.gc_num() = zero_gc_num()
@device_override Base.cumulative_compile_timing(b::Bool) = nothing
@device_override Base.cumulative_compile_time_ns() = (UInt64(0), UInt64(0))
@device_override Base.Threads.lock_profiling(b::Bool) = nothing
# The number of allocations is not zero but -1, which `@allocations` returns to the program: 0 would be taken to be an answer
# (`@allocations f() == 0` would be true for a function that allocates), and -1 can only be taken to be none. `time_print`
# does not write what is counted.
@device_override Base.gc_alloc_count(diff::Base.GC_Diff) = -1
@device_override function Base.time_print(io::IO, elapsedtime, bytes = 0, gctime = 0, allocs = 0, lock_conflicts = 0, compile_time = 0, recompile_time = 0, newline = false; msg::Union{String,Nothing} = nothing)
    timestr = Base.Ryu.writefixed(Float64(elapsedtime / 1e9), 6)
    if msg isa String
        print(io, msg, ": ")
    else
        print(io, length(timestr) < 10 ? (" "^(10 - length(timestr))) : "")
    end
    print(io, timestr, " seconds", newline ? "\n" : "")
    nothing
end

# Libraries opened when the program runs (`Libdl.dlopen`, `dlsym`, `dlclose`): Julia's functions are those of libjulia
# (`jl_load_dynamic_library`, which also adds the extension and searches `DL_LOAD_PATH`), so these are the C library's
# `dlopen`, `dlsym` and `dlclose`. The flags of Libdl are Julia's own numbers, which are translated to those of the system.
# Not kept: `DL_LOAD_PATH`, `@executable_path/` in a name. The library is tried as it is and then with the extension.
function dl_flags(flags::UInt32)
    f = Cint(0)
    if target_macos()
        flags & Runtime.Libdl.RTLD_LAZY != 0 && (f |= 0x1)
        flags & Runtime.Libdl.RTLD_NOW != 0 && (f |= 0x2)
        flags & Runtime.Libdl.RTLD_LOCAL != 0 && (f |= 0x4)
        flags & Runtime.Libdl.RTLD_GLOBAL != 0 && (f |= 0x8)
        flags & Runtime.Libdl.RTLD_NOLOAD != 0 && (f |= 0x10)
        flags & Runtime.Libdl.RTLD_NODELETE != 0 && (f |= 0x80)
        flags & Runtime.Libdl.RTLD_FIRST != 0 && (f |= 0x100)
    else
        flags & Runtime.Libdl.RTLD_LAZY != 0 && (f |= 0x1)
        flags & Runtime.Libdl.RTLD_NOW != 0 && (f |= 0x2)
        flags & Runtime.Libdl.RTLD_NOLOAD != 0 && (f |= 0x4)
        flags & Runtime.Libdl.RTLD_DEEPBIND != 0 && (f |= 0x8)
        flags & Runtime.Libdl.RTLD_GLOBAL != 0 && (f |= 0x100)
        flags & Runtime.Libdl.RTLD_NODELETE != 0 && (f |= 0x1000)
    end
    return f
end

@device_override function Runtime.Libdl.dlopen(s::AbstractString, flags::Integer = Runtime.Libdl.default_rtld_flags; throw_error::Bool = true)
    f = dl_flags(UInt32(flags))
    h = ccall(:dlopen, Ptr{Cvoid}, (Cstring, Cint), s, f)
    ext = string(".", Runtime.Libdl.dlext)
    h == C_NULL && !endswith(s, ext) && (h = ccall(:dlopen, Ptr{Cvoid}, (Cstring, Cint), string(s, ext), f))
    if h == C_NULL
        throw_error || return nothing
        msg = ccall(:dlerror, Cstring, ())
        error(msg == C_NULL ? "could not load library" : unsafe_string(msg))
    end
    return h
end

@device_override function Runtime.Libdl.dlsym(hnd::Ptr, s::Union{Symbol,AbstractString}; throw_error::Bool = true)
    hnd == C_NULL && throw(ArgumentError("NULL library handle"))
    p = ccall(:dlsym, Ptr{Cvoid}, (Ptr{Cvoid}, Cstring), hnd, s)
    if p == C_NULL
        throw_error || return nothing
        error("could not load symbol \"", s, "\"")
    end
    return p
end

@device_override Runtime.Libdl.dlclose(p::Ptr) = 0 == ccall(:dlclose, Cint, (Ptr{Cvoid},), p)

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

# The memory of the machine (`Sys.total_memory()`, `Sys.free_memory()`, ...), which Base asks libuv for: the total from
# `sysctl` (macOS) or `sysconf` (Linux); what is free as libuv has it, the free pages of Mach's statistics (macOS) or
# `MemAvailable` of `/proc/meminfo` (Linux). The limit of a control group (`uv_get_constrained_memory`, Linux) is not
# read: the total is the physical memory.
function physical_memory()
    if target_macos()
        v = Ref{UInt64}(0)
        n = Ref{Csize_t}(sizeof(UInt64))
        ok = ccall(:sysctlbyname, Cint, (Cstring, Ptr{UInt64}, Ptr{Csize_t}, Ptr{Cvoid}, Csize_t), "hw.memsize", v, n, C_NULL, 0) == 0
        return ok ? v[] : UInt64(0)
    else
        return UInt64(ccall(:sysconf, Clong, (Cint,), 85)) * UInt64(ccall(:sysconf, Clong, (Cint,), 30)) # (`_SC_PHYS_PAGES`, `_SC_PAGESIZE`)
    end
end
function free_memory_bytes()
    if target_macos()
        info = zeros(UInt32, 40) # (a `vm_statistics_data_t`: the number of free pages is its first field)
        count = Ref{UInt32}(15)  # (`HOST_VM_INFO_COUNT`)
        host = ccall(:mach_host_self, UInt32, ())
        ok = GC.@preserve info ccall(:host_statistics, Cint, (UInt32, Cint, Ptr{UInt32}, Ptr{UInt32}), host, 2, pointer(info), count) == 0
        return ok ? UInt64(info[1]) * UInt64(ccall(:sysconf, Clong, (Cint,), 29)) : UInt64(0) # (2: `HOST_VM_INFO`; 29: `_SC_PAGESIZE`)
    else
        for line in eachline("/proc/meminfo")
            startswith(line, "MemAvailable:") && return parse(UInt64, split(line)[2]) * UInt64(1024)
        end
        return UInt64(ccall(:sysconf, Clong, (Cint,), 86)) * UInt64(ccall(:sysconf, Clong, (Cint,), 30)) # (`_SC_AVPHYS_PAGES`)
    end
end
@device_override Base.Sys.total_physical_memory() = physical_memory()
@device_override Base.Sys.total_memory() = physical_memory()
@device_override Base.Sys.free_physical_memory() = free_memory_bytes()
@device_override Base.Sys.free_memory() = free_memory_bytes()
