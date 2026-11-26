# Files and streams (src/files.jl, src/io.jl): what a program does with files, compared with Julia's. The same function runs in Julia (with the streams of Base) and compiled (with libc's);
# they write and read files in different directories, and print what they find, which must be the same. Also the standard streams as files, binary data, and what is said of errors.

# Files: what a program does with them is compared with Julia's. The same function runs in Julia (with
# the streams of Base) and compiled (with libc's); they write and read files in different directories,
# and print what they find, which must be the same
@testset "Files" begin
    @eval function file_demo(dir::String)
        path = string(dir, "/demo.txt")
        # write: do-block, print, println, @printf, write of a byte and of a string
        open(path, "w") do io
            println(io, "first line")
            print(io, "second ", 2, " line\n")
            Printf.@printf(io, "%s %d %5.2f\n", "third", 3, 3.14159)
            Printf.@printf(io, "%s=%d\n", "four", 4)
            write(io, 0x35)
            write(io, "5th\n")
        end
        # read it back in several ways
        text = read(path, String)
        println("text: ", length(text), " ", count(==('\n'), text))
        print(text)
        lines = readlines(path)
        println("lines: ", length(lines), " ", lines[end])
        open(path) do io
            println("first: ", readline(io))
            println("eof? ", eof(io), " position: ", position(io))
            n = 0
            while !eof(io)
                n += length(readline(io))
            end
            println("rest: ", n, " eof? ", eof(io))
            seekstart(io)
            println("again: ", read(io, UInt8), " ", read(io, UInt8), " position ", position(io))
            seekend(io)
            println("end: ", position(io), " ", filesize(io))
            seek(io, 6)
            println("seek: ", read(io, UInt8) == UInt8('l'))
        end
        # eachline, count, append, and a second file
        println("eachline: ", sum(length, eachline(path)))
        open(path, "a") do io
            println(io, "appended")
        end
        println("after append: ", length(readlines(path)))
        write(string(dir, "/other.txt"), "x = ", 42, "\n")
        println("other: ", read(string(dir, "/other.txt"), String))
        # a file that does not exist
        failed = try
            open(string(dir, "/missing/none.txt"))
            false
        catch
            true
        end
        println("missing: ", failed)
        return nothing
    end
    @eval file_main(args::Vector{String}) = (file_demo(args[1]); 0)

    host_dir, exe_dir = mktempdir(), mktempdir()
    expected = let (path, io) = mktemp()
        try
            redirect_stdout(io) do
                Base.invokelatest(file_demo, host_dir)
                flush(stdout)
            end
        finally
            close(io)
        end
        read(path, String)
    end
    exe = Base.invokelatest(compile_executable, file_main, (Vector{String},), mktempdir())
    @test read(`$exe $exe_dir`, String) == expected
    # and the files written are the same ones
    @test read(joinpath(host_dir, "demo.txt"), String) == read(joinpath(exe_dir, "demo.txt"), String)
    @test read(joinpath(host_dir, "other.txt"), String) == read(joinpath(exe_dir, "other.txt"), String)
end

# The keywords of `open` (`read`, `write`, `create`, `truncate`, `append`, `lock`: the file is opened with the flags that Base works out from them) and of `readline`, `readlines` and `eachline` (`keep`)
okpath(n) = string(tempdir(), "/static_open_keywords_", getpid(), "_", n, ".txt")
@testset "Keywords of open, readline and eachline" begin
    check_cases([
        "read = true"                  => () -> (p = okpath(1); write(p, "ab\ncd\n"); open(p; read = true) do io; println(readline(io)); end; rm(p); 0),
        "write = true truncates"       => () -> (p = okpath(2); write(p, "long old content\n"); open(p; write = true) do io; print(io, "new\n"); end; println(repr(read(p, String))); rm(p); 0),
        "append = true"                => () -> (p = okpath(3); write(p, "a\n"); open(p; append = true) do io; print(io, "b\n"); end; println(repr(read(p, String))); rm(p); 0),
        "read and write"               => () -> (p = okpath(4); write(p, "abcdef"); open(p; read = true, write = true) do io; write(io, "XY"); seekstart(io); println(repr(read(io, String))); end; rm(p); 0),
        "write without truncating"     => () -> (p = okpath(5); write(p, "abcdef"); open(p; write = true, truncate = false) do io; write(io, "XY"); end; println(repr(read(p, String))); rm(p); 0),
        "truncate and read"            => () -> (p = okpath(6); write(p, "abcdef"); open(p; truncate = true, read = true) do io; write(io, "Z"); seekstart(io); println(repr(read(io, String))); end; rm(p); 0),
        "append and read"              => () -> (p = okpath(7); write(p, "a\n"); open(p; append = true, read = true) do io; write(io, "b\n"); seekstart(io); println(repr(read(io, String))); end; rm(p); 0),
        "create = false, no file"      => () -> (p = okpath(8); r = try; open(p; write = true, create = false) do io; 1; end; catch e; 2; end; println(r); 0),
        "read = true, no file"         => () -> (p = okpath(9); r = try; open(p; read = true) do io; 1; end; catch e; 2; end; println(r); 0),
        "lock = false"                 => () -> (p = okpath(10); write(p, "q\n"); io = open(p; lock = false); println(readline(io)); close(io); rm(p); 0),
        "readline of a stream, keep"   => () -> (p = okpath(11); write(p, "ab\ncd\n"); open(p, "r") do io; println(repr(readline(io; keep = true))); end; rm(p); 0),
        "readline of a file, keep"     => () -> (p = okpath(12); write(p, "ab\ncd\n"); println(repr(readline(p; keep = true))); rm(p); 0),
        "readlines of a file, keep"    => () -> (p = okpath(13); write(p, "ab\ncd\n"); println(repr(readlines(p; keep = true))); rm(p); 0),
        "eachline of a file, keep"     => () -> (p = okpath(14); write(p, "ab\ncd\n"); for l in eachline(p; keep = true); println(repr(l)); end; rm(p); 0),
        "eachline of a stream, keep"   => () -> (p = okpath(15); write(p, "ab\ncd\n"); open(p, "r") do io; for l in eachline(io; keep = true); println(repr(l)); end; end; rm(p); 0),
    ])
end

# the forms of `readline`, `readlines` and `eachline` that read the standard input without naming it
@testset "Standard input without naming it" begin
    @eval function stdin_forms_main(args::Vector{String})
        first = readline()
        println("first: ", first)
        count = 0
        for line in eachline()
            count += 1
            println(count, ": ", line)
            count == 2 && break
        end
        rest = readlines()
        println("rest: ", length(rest), " ", isempty(rest) ? "" : rest[end])
        return 0
    end
    exe = Base.invokelatest(compile_executable, stdin_forms_main, (Vector{String},), mktempdir())
    input = "one\ntwo\nthree\nfour\nfive\nsix"
    @test read(pipeline(`$exe`; stdin = IOBuffer(input)), String) == "first: one\n1: two\n2: three\nrest: 3 six\n"
end

# Binary data: numbers and arrays of numbers, written and read back, compared with Julia's
@testset "Files: binary data" begin
    @eval function binary_demo(dir::String)
        path = string(dir, "/data.bin")
        open(path, "w") do io
            write(io, Int32(-5))
            write(io, 2.5)
            write(io, UInt8[1, 2, 3, 4])
            write(io, [10, 20, 30])
            write(io, 'x')
            write(io, UInt16(65535))
        end
        println("size: ", filesize(path))
        open(path) do io
            println(read(io, Int32), " ", read(io, Float64))
            bytes = read(io, 4)
            println(length(bytes), " ", sum(bytes), " ", bytes[end])
            v = Vector{Int}(undef, 3)
            read!(io, v)
            println(v[1], " ", v[2], " ", v[3], " ", read(io, Char), " ", read(io, UInt16), " ", eof(io))
            seekstart(io)
            println(length(read(io)), " ", position(io))
        end
        return nothing
    end
    @eval binary_main(args::Vector{String}) = (binary_demo(args[1]); 0)
    host_dir, exe_dir = mktempdir(), mktempdir()
    expected = let (path, io) = mktemp()
        try
            redirect_stdout(io) do
                Base.invokelatest(binary_demo, host_dir)
                flush(stdout)
            end
        finally
            close(io)
        end
        read(path, String)
    end
    exe = Base.invokelatest(compile_executable, binary_main, (Vector{String},), mktempdir())
    @test read(`$exe $exe_dir`, String) == expected
    @test read(joinpath(host_dir, "data.bin")) == read(joinpath(exe_dir, "data.bin"))
end

# Errors of libc that were ignored: a file that can't be written (a full disk) was closed without a word
@static if Sys.islinux()
    full_disk() = (io = open("/dev/full", "w"); write(io, "data"); close(io); 1)
    full_disk_flush() = (io = open("/dev/full", "w"); write(io, "data"); flush(io); close(io); 1)
    @testset "Write errors" begin
        @test static_status(full_disk)[1] == :runtime_error
        @test static_status(full_disk_flush)[1] == :runtime_error
    end
end

# A file that was closed has no `FILE*`: reading it was a call of libc with a null pointer
closed_read() = (path = "/tmp/static_overrides_closed_test.txt"; write(path, "abc"); io = open(path); close(io); try; read(io, UInt8); 0; catch; 1; end)
@testset "A file that is closed" begin
    @test static_status(closed_read)[1] == :ok
end


## the operating system: the process, the environment, the clock and threads

# The operating system: the file system (paths, `stat`, directories, copying, temporary files), the environment (`ENV`), the process, the clock, `sleep`, and `Threads.@threads` (which runs
# the iterations one after another).
# The functions are the ones of Base, written with the functions of the C library (src/filesystem.jl); what they do is compared with Julia's (a directory is made for each case).

function threads_sum(s)
    Threads.@threads for i in 1:10
        Threads.atomic_add!(s, i)
    end
    return s[]
end

@testset "The file system and the process" begin
    dir() = (d = joinpath(tempdir(), string("static_cov_", Libc.getpid())); isdir(d) && rm(d; recursive = true); mkdir(d); d)
    check_cases([
        "paths"                    => () -> (println(basename("/a/b.txt"), dirname("/a/b.txt"), splitext("b.txt"), joinpath("a", "b"), normpath("/a/../b")); 0),
        "mkdir, isdir, rm"         => () -> (d = dir(); r = Int(isdir(d)); rm(d); r + Int(isdir(d)) + Int(ispath(d))),
        "files: isfile, filesize"  => () -> (d = dir(); p = joinpath(d, "f"); write(p, "hello"); r = Int(isfile(p)) + Int(ispath(p)) + filesize(p) + Int(isdir(p)); rm(d; recursive = true); r),
        "stat"                     => () -> (d = dir(); p = joinpath(d, "f"); write(p, "abc"); s = stat(p); r = Int(s.size) + Int(mtime(p) > 0) + Int(filemode(p) & 0o400 != 0); rm(d; recursive = true); r),
        "readdir"                  => () -> (d = dir(); write(joinpath(d, "b.txt"), "y"); write(joinpath(d, "a.txt"), "x"); mkdir(joinpath(d, "sub")); n = readdir(d); println(n); println(readdir(d; join = true) == joinpath.(d, n)); rm(d; recursive = true); length(n)),
        "cp and mv"                => () -> (d = dir(); p = joinpath(d, "f"); write(p, "abc"); cp(p, p * "2"); mv(p * "2", p * "3"); r = length(read(p * "3", String)) + Int(!ispath(p * "2")); rm(d; recursive = true); r),
        "cp of a directory"        => () -> (d = dir(); mkdir(joinpath(d, "s")); write(joinpath(d, "s", "x"), "hi"); cp(joinpath(d, "s"), joinpath(d, "t")); r = length(read(joinpath(d, "t", "x"), String)); rm(d; recursive = true); r),
        "rm of what is not there"  => () -> (d = dir(); rm(joinpath(d, "nothing"); force = true); r = (try; rm(joinpath(d, "nothing")); 0; catch e; 1; end); rm(d); r),
        "mkdir of one that exists" => () -> (d = dir(); r = (try; mkdir(d); 0; catch e; 1; end); rm(d); r),
        "pwd and cd"               => () -> (d = realpath(dir()); old = pwd(); cd(d); r = Int(realpath(pwd()) == d); cd(old); rm(d); r + Int(pwd() == old)),
        "temporary files"          => () -> ((p, io) = mktemp(); close(io); r = Int(isfile(p)); rm(p); q = tempname(); r + Int(!ispath(q)) + Int(isdir(tempdir()))),
        "mktempdir with a function" => () -> (path = mktempdir(d -> (write(joinpath(d, "x"), "1"); d)); Int(!ispath(path))),
        "environment"              => () -> (ENV["STATIC_COVERAGE_X"] = "5"; r = parse(Int, ENV["STATIC_COVERAGE_X"]) + Int(haskey(ENV, "STATIC_COVERAGE_X")); delete!(ENV, "STATIC_COVERAGE_X"); r + Int(haskey(ENV, "STATIC_COVERAGE_X"))),
        "process id and homedir"   => () -> Int(Libc.getpid() > 0) + Int(length(homedir()) > 0),
        "@threads"                 => () -> (s = Threads.Atomic{Int}(0); threads_sum(s)),
        "chmod"                    => () -> (d = dir(); p = joinpath(d, "f"); write(p, "x"); chmod(p, 0o600); r = filemode(p) & 0o777; chmod(p, 0o644); println(string(r, base = 8), " ", string(filemode(p) & 0o777, base = 8)); rm(d; recursive = true); 0),
        "symlink and readlink"     => () -> (d = dir(); p = joinpath(d, "f"); write(p, "abc"); q = joinpath(d, "l"); symlink(p, q); println(readlink(q) == p, " ", islink(q), " ", read(q, String)); rm(d; recursive = true); 0),
        "readlink of what is not there" => () -> (try; readlink(joinpath(dir(), "nothing")); 0; catch e; 1; end),
        "walkdir"                  => () -> (d = dir(); mkpath(joinpath(d, "a", "b")); write(joinpath(d, "a", "f"), "x"); write(joinpath(d, "g"), "y"); for (root, dirs, files) in walkdir(d); println(relpath(root, d), " ", dirs, " ", files); end; rm(d; recursive = true); 0),
        "gethostname"              => () -> (println(gethostname() == gethostname(), " ", !isempty(gethostname())); 0),
        "Libc.strftime"            => () -> (println(Libc.strftime("%Y-%m-%d %H:%M", 86400.0 * 400 + opaque(0.0))); 0),
        "the memory of the machine" => () -> (println(Sys.total_memory(), " ", Sys.total_physical_memory(), " ", Sys.free_memory() > 0, " ", Sys.free_physical_memory() > 0); 0),
    ])
end


@testset "Time and threads" begin
    check_cases([
    "time_ns/time"          => () -> (t = time_ns(); Int(time_ns() >= t) + Int(time() > 1e9)),
    "nthreads"              => () -> Threads.nthreads(),
        "sleep"                   => () -> (t = time(); sleep(0.05); println(time() - t >= 0.04); 0),
        "sleep with a bad time"   => () -> (try; sleep(-1); catch e; println(e isa ArgumentError); end; 0),
    ], folded_ok = ("nthreads",)) # (the number of threads is the same for the whole run: a constant)
end

# `pkgversion` of a module that is known is the version that the package had when the program was compiled (it is not read from the `Project.toml` when the program runs)
@testset "pkgversion" begin
    @eval pkgversion_main(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println("v ", pkgversion(StaticRuntime), " ", pkgversion(Base) === nothing); 0)
    @test run_main(pkgversion_main) == "v $(pkgversion(StaticRuntime)) $(pkgversion(Base) === nothing)"
end
