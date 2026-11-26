# Starting other programs: `run`, `success`, `read` (and so `readchomp`, `read(cmd, String)`) and `readlines` of a `Cmd`.
#
# Base does this with libuv (`uv_spawn`, pipes in the event loop), which needs the runtime. Here the program is started
# with `posix_spawnp` and waited for with `waitpid`, and the output of `read` comes through a pipe that is read to its end
# before the wait. What is done: the arguments, `ignorestatus`, `setenv` (the whole environment of the program is the list),
# `dir` (`posix_spawn_file_actions_addchdir_np`: macOS 10.15, glibc 2.29), and the redirects of `pipeline(cmd; stdin, stdout,
# stderr, append)`: to a file, to `devnull`, to `stdout`/`stderr`/`stdin` of the program. What is not: a pipe from a command to
# another (`pipeline(a, b)`, `a & b`), `run(cmd; wait = false)`, a stream that is not one of those as a redirect, `open(cmd)`,
# `eachline(cmd)`, and a program that is started with `detach`, `cpus`, `uid` or `gid` (these are not looked at). A command that
# can not be started (not found, not executable) throws a `SystemError`, where Base's is an `IOError`.

# the flags of `open`, as the system has them
@inline spawn_o_creat() = target_choice(0x200, 0x40)
@inline spawn_o_trunc() = target_choice(0x400, 0x200)
@inline spawn_o_append() = target_choice(0x8, 0x400)
const SPAWN_O_RDONLY, SPAWN_O_WRONLY = 0x0, 0x1

# (`posix_spawn_file_actions_t` is a pointer on macOS and 80 bytes on glibc: a buffer that is larger than both)
const SPAWN_ACTIONS_BYTES = 256

# the environment of the program, as `execve` has it
function spawn_environ()
    if target_macos()
        return unsafe_load(ccall(:_NSGetEnviron, Ptr{Ptr{Ptr{UInt8}}}, ()))
    else
        return unsafe_load(cglobal(:environ, Ptr{Ptr{UInt8}}))
    end
end

spawn_error(cmd::Base.Cmd, what::AbstractString, code::Integer) = throw(SystemError(string(what, " ", join(cmd.exec, ' ')), Int(code)))

# `cmd`, and the redirects of it: the file descriptors and what they are made to be, innermost first (the order that they are made
# in): `pipeline(cmd, stdout = a, stderr = b)` is `CmdRedirect(CmdRedirect(cmd, a, 1), b, 2)`
function spawn_parts(cmd::Base.AbstractCmd)
    fds = Int[]
    handles = Any[]
    while cmd isa Base.CmdRedirect
        pushfirst!(fds, cmd.stream_no)
        pushfirst!(handles, cmd.handle)
        cmd = cmd.cmd
    end
    cmd isa Base.Cmd || error("a pipeline of commands (`pipeline(a, b)`, `a & b`) is not supported in a compiled program: only a command, with `pipeline(cmd; stdin, stdout, stderr)`")
    return cmd, fds, handles
end

function spawn_action_open!(actions::Ptr{Cvoid}, fd::Int, path::String, flags::Integer)
    r = GC.@preserve path ccall(:posix_spawn_file_actions_addopen, Cint, (Ptr{Cvoid}, Cint, Cstring, Cint, UInt32), actions, fd, path, flags, 0x000001b6) # 0o666 (`mode_t` is 16 bits on macOS and 32 on Linux: a register that has more than the callee reads is fine, the other way is not)
    r == 0 || throw(SystemError("posix_spawn_file_actions_addopen", Int(r)))
    return nothing
end

function spawn_action_dup!(actions::Ptr{Cvoid}, from::Int, to::Int)
    r = ccall(:posix_spawn_file_actions_adddup2, Cint, (Ptr{Cvoid}, Cint, Cint), actions, from, to)
    r == 0 || throw(SystemError("posix_spawn_file_actions_adddup2", Int(r)))
    return nothing
end

# one redirect of file descriptor `fd`
function spawn_redirect!(actions::Ptr{Cvoid}, fd::Int, handle)
    if handle isa Base.FileRedirect
        flags = fd == 0 ? SPAWN_O_RDONLY : (SPAWN_O_WRONLY | spawn_o_creat() | (handle.append ? spawn_o_append() : spawn_o_trunc()))
        spawn_action_open!(actions, fd, handle.filename, flags)
    elseif handle isa Base.DevNull
        spawn_action_open!(actions, fd, "/dev/null", fd == 0 ? SPAWN_O_RDONLY : SPAWN_O_WRONLY)
    elseif handle isa StaticIO{:stdin}
        spawn_action_dup!(actions, 0, fd)
    elseif handle isa StaticIO{:stdout}
        spawn_action_dup!(actions, 1, fd)
    elseif handle isa StaticIO{:stderr}
        spawn_action_dup!(actions, 2, fd)
    elseif handle isa Base.RawFD
        spawn_action_dup!(actions, Int(handle.fd), fd)
    else
        error("a redirect of a command to a stream that is not a file, `devnull`, `stdin`, `stdout` or `stderr` is not supported in a compiled program")
    end
    return nothing
end

# Starts `cmd` and waits for it. With `capture`, what it writes to its standard output is read (its standard input is `devnull`,
# as Base's `read` has it), and is the second value. The first is the `Process` that Base has for a command that has ended (the
# status is in `exitcode` and `termsignal`), which is what `ProcessFailedException` holds.
function spawn_and_wait(cmds::Base.AbstractCmd, capture::Bool)
    cmd, redirect_fds, redirect_handles = spawn_parts(cmds)
    isempty(cmd.exec) && throw(ArgumentError("cannot spawn an empty command"))
    # (what the program has written is out before what the other writes)
    ccall(:fflush, Cint, (Ptr{Cvoid},), C_NULL)
    actions = zeros(UInt8, SPAWN_ACTIONS_BYTES)
    fds = Cint[-1, -1]
    out = UInt8[]
    pid = Ref{Cint}(0)
    GC.@preserve actions fds pid begin
        ap = Ptr{Cvoid}(pointer(actions))
        r = ccall(:posix_spawn_file_actions_init, Cint, (Ptr{Cvoid},), ap)
        r == 0 || throw(SystemError("posix_spawn_file_actions_init", Int(r)))
        try
            if capture
                ccall(:pipe, Cint, (Ptr{Cint},), pointer(fds)) == 0 || throw(SystemError("pipe", Int(unsafe_load(errno_pointer()))))
                spawn_action_open!(ap, 0, "/dev/null", SPAWN_O_RDONLY)
                spawn_action_dup!(ap, Int(fds[2]), 1)
                ccall(:posix_spawn_file_actions_addclose, Cint, (Ptr{Cvoid}, Cint), ap, fds[1])
                ccall(:posix_spawn_file_actions_addclose, Cint, (Ptr{Cvoid}, Cint), ap, fds[2])
            end
            for i in eachindex(redirect_fds)
                spawn_redirect!(ap, redirect_fds[i], redirect_handles[i])
            end
            if !isempty(cmd.dir)
                r = GC.@preserve cmd ccall(:posix_spawn_file_actions_addchdir_np, Cint, (Ptr{Cvoid}, Cstring), ap, cmd.dir)
                r == 0 || throw(SystemError("posix_spawn_file_actions_addchdir_np", Int(r)))
            end
            exec = cmd.exec
            argv = Vector{Ptr{UInt8}}(undef, length(exec) + 1)
            for i in eachindex(exec)
                argv[i] = pointer(exec[i])
            end
            argv[end] = Ptr{UInt8}(0)
            env = cmd.env
            envp = Vector{Ptr{UInt8}}(undef, env === nothing ? 0 : length(env) + 1)
            if env !== nothing
                for i in eachindex(env)
                    envp[i] = pointer(env[i])
                end
                envp[end] = Ptr{UInt8}(0)
            end
            GC.@preserve exec argv env envp begin
                envptr = env === nothing ? spawn_environ() : Ptr{Ptr{UInt8}}(pointer(envp))
                r = ccall(:posix_spawnp, Cint, (Ptr{Cint}, Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Ptr{UInt8}}),
                          pid, exec[1], ap, C_NULL, pointer(argv), envptr)
            end
            if capture
                ccall(:close, Cint, (Cint,), fds[2]); fds[2] = -1 # (so that the end of what it writes is the end of the file)
            end
            if r != 0
                capture && (ccall(:close, Cint, (Cint,), fds[1]); fds[1] = -1)
                spawn_error(cmd, "could not spawn", r)
            end
            if capture
                buf = Vector{UInt8}(undef, 4096)
                while true
                    n = GC.@preserve buf ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fds[1], pointer(buf), length(buf))
                    if n < 0
                        unsafe_load(errno_pointer()) == 4 && continue # (EINTR)
                        break
                    end
                    n == 0 && break
                    append!(out, view(buf, 1:Int(n)))
                end
            end
        finally
            ccall(:posix_spawn_file_actions_destroy, Cint, (Ptr{Cvoid},), ap)
            fds[1] >= 0 && ccall(:close, Cint, (Cint,), fds[1])
            fds[2] >= 0 && ccall(:close, Cint, (Cint,), fds[2])
        end
    end
    status = Cint[0]
    while true
        w = GC.@preserve status ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid[], pointer(status), 0)
        w >= 0 && break
        unsafe_load(errno_pointer()) == 4 || spawn_error(cmd, "could not wait for", unsafe_load(errno_pointer()))
    end
    st = Int(status[1])
    proc = Base.Process(cmd, Ptr{Cvoid}(0), Task[])
    if (st & 0x7f) == 0
        proc.exitcode = (st >> 8) & 0xff
        proc.termsignal = 0
    else
        proc.exitcode = 0
        proc.termsignal = st & 0x7f
    end
    return proc, out
end

spawn_success(proc::Base.Process) = proc.exitcode == 0 && proc.termsignal == 0

@device_override function Base.run(cmds::Base.AbstractCmd, args...; wait::Bool = true)
    (isempty(args) && wait) || error("`run` of a command with streams as arguments, or with `wait = false`, is not supported in a compiled program: use `pipeline` for the redirects")
    proc, _ = spawn_and_wait(cmds, false)
    spawn_success(proc) || Base.pipeline_error(proc)
    return proc
end

@device_override function Base.success(cmds::Base.AbstractCmd)
    proc, _ = spawn_and_wait(cmds, false)
    return spawn_success(proc)
end

@device_override function Base.read(cmds::Base.AbstractCmd)
    proc, out = spawn_and_wait(cmds, true)
    spawn_success(proc) || Base.pipeline_error(proc)
    return out
end

@device_override Base.read(cmds::Base.AbstractCmd, ::Type{String}) = String(Base.read(cmds))

# (the `Process` of a command that has ended has no handle of libuv to close)
@device_override Base.uvfinalize(proc::Base.Process) = nothing

## `cmd_gen`, which is what `` `...` `` makes of the words: Base splats tuples of any length (`arg_gen(arg...)`), which a compiled program can't. A word is a
## tuple of pieces (`"a$x.txt"` is `("a", x, ".txt")`), each of which gives the strings that are put together, with every combination of
## those of the others when there are several (`$(["a", "b"])`), as `arg_gen` does; a `Cmd` as the first word gives its arguments and settings.

cmd_pieces(x::AbstractString) = String[String(x)]
cmd_pieces(x::AbstractArray) = String[Base.cmd_interpolate(e) for e in x]
cmd_pieces(x::Base.Cmd) = error("a command can only be the first word of a command")
cmd_pieces(x) = String[Base.cmd_interpolate(x)]

# (every combination of the strings that are so far and those of the next piece, the first ones changing the slowest)
function cmd_cross(vals::Vector{String}, more::Vector{String})
    next = String[]
    for h in vals, t in more
        push!(next, string(h, t))
    end
    return next
end

# (the words and the pieces of a word are tuples of different types, which are taken apart by their types, one at a time)
cmd_word!(vals::Vector{String}, ::Tuple{}) = vals
cmd_word!(vals::Vector{String}, word::Tuple) = cmd_word!(cmd_cross(vals, cmd_pieces(first(word))), Base.tail(word))
cmd_words!(args::Vector{String}, ::Tuple{}) = args
function cmd_words!(args::Vector{String}, parsed::Tuple)
    append!(args, cmd_word!(String[""], first(parsed)))
    return cmd_words!(args, Base.tail(parsed))
end

cmd_gen_static(parsed::Tuple) = Base.Cmd(cmd_words!(String[], parsed))
function cmd_gen_static(parsed::Tuple{Tuple{Base.Cmd},Vararg{Tuple}})
    cmd = parsed[1][1]
    args = copy(cmd.exec)
    cmd_words!(args, Base.tail(parsed))
    return Base.Cmd(Base.Cmd(args), cmd.ignorestatus, cmd.flags, cmd.env, cmd.dir, cmd.cpus, cmd.uid, cmd.gid)
end

@device_override Base.cmd_gen(parsed::Tuple) = cmd_gen_static(parsed)
@device_override Base.cmd_gen(parsed::Tuple{Vararg{Tuple{Vararg{Union{String,SubString{String}}}}}}) = cmd_gen_static(parsed)
