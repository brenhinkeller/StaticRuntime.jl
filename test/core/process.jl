# Other programs (src/overrides/process.jl): `run`, `success`, `read` and the redirects of a `Cmd`, compared with Julia's. (What is not the same: a command that can not be
# started throws a `SystemError`, where Base's is an `IOError`, so it is tested apart.)

@testset "Processes" begin
    shell = "sh"
    cases = [
        "run"                 => () -> (println("before"); flush(stdout); run(`echo hello from run`); println("after"); 0),
        "success"             => () -> (println(success(`true`), " ", success(`false`)); 0),
        "read String"         => () -> (println(repr(read(`echo captured`, String))); 0),
        "readchomp"           => () -> (println(readchomp(`printf abc`)); 0),
        "read bytes"          => () -> (b = read(`printf xyz`); println(b, " ", length(b)); 0),
        "read of a lot"       => () -> (println(length(read(`sh -c "yes abcdefgh | head -c 200000"`))); 0),
        "failed process"      => () -> (try run(`false`); 0 catch e; e isa ProcessFailedException ? (println(e.procs[1].exitcode); 1) : 2 end),
        "failed read"         => () -> (try read(`sh -c "echo out; exit 3"`, String); 0 catch e; e isa ProcessFailedException ? (println(e.procs[1].exitcode); 1) : 2 end),
        "ignorestatus"        => () -> (run(ignorestatus(`sh -c "exit 4"`)); println("went on"); 0),
        "signal"              => () -> (try run(`sh -c "kill -9 \$\$"`) catch e; e isa ProcessFailedException && println(e.procs[1].termsignal, " ", e.procs[1].exitcode) end; 0),
        "devnull"             => () -> (run(pipeline(`echo hidden`, stdout = devnull)); run(pipeline(`sh -c "echo hidden >&2"`, stderr = devnull)); println("done"); 0),
        "stderr to stdout"    => () -> (run(pipeline(`sh -c "echo e >&2; echo o"`, stderr = stdout)); 0),
        "stdout to a file"    => () -> (f = tempname(); run(pipeline(`echo one`, stdout = f)); run(pipeline(`echo two`, stdout = f, append = true)); print(read(f, String)); rm(f); 0),
        "stdin from a file"   => () -> (f = tempname(); write(f, "from a file\n"); run(pipeline(f, `cat`)); run(pipeline(`cat`, stdin = f)); rm(f); 0),
        "dir"                 => () -> (println(read(Cmd(`pwd`, dir = "/"), String)); 0),
        "env"                 => () -> (println(read(Cmd(`sh -c "echo \$FOO"`, env = ["FOO=bar", "PATH=/bin:/usr/bin"]), String)); 0),
        "interpolation"       => () -> (x = "a b"; n = 42; v = ["p", "q"]; run(`printf "[%s]" $x $n $v`); println(); flush(stdout); run(`printf "[%s]" "$x.txt" $v.ext`); println(); 0),
        "a Cmd in a Cmd"      => () -> (c = `echo a`; run(`$c b c`); ic = ignorestatus(`false`); run(`$ic b`); 0),
        "output is ordered"   => () -> (print("one "); flush(stdout); run(`echo two`); print("three "); flush(stdout); println(read(`echo four`, String)); 0),
    ]
    check_cases(cases)

    # `environ`, the environment that a program that is started has by default, is a variable of the C library: `cglobal` of it is the address of the variable, which the program links to
    @eval function process_environ(argc::Int, argv::Ptr{Ptr{UInt8}})
        e = unsafe_load(cglobal(:environ, Ptr{Ptr{UInt8}}))
        n = 0
        while unsafe_load(e, n + 1) != Ptr{UInt8}(0)
            n += 1
        end
        println(n > 0)
        return 0
    end
    exe = compile_executable(process_environ, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "process_environ")
    @test readchomp(`$exe`) == "true"

    # a program that can not be started (not found, not executable)
    @eval function process_not_found()
        try
            run(`/nonexistent/program`)
            return 0
        catch e
            return e isa SystemError ? 1 : e isa Base.IOError ? 1 : 2
        end
    end
    @test static_status(process_not_found)[1] == :ok

    # a pipe between commands is refused, and with a message
    @eval pipe_between_commands() = (run(pipeline(`echo a`, `cat`)); 0)
    @test static_status(pipe_between_commands)[1] in (:compile_error, :runtime_error, :mismatch)
end
