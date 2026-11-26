# Scripts (src/script.jl): a script compiled with `compile_script_string` does what `julia script.jl args...` does. Each case is the code, the arguments and what it prints.

function script_run(code, args = String[]; kwargs...)
    exe = compile_script_string(code, mktempdir(), "script"; kwargs...)
    out, err = tempname(), tempname()
    p = run(ignorestatus(pipeline(`$exe $args`; stdout = out, stderr = err)))
    return read(out, String), p.exitcode, read(err, String)
end

@testset "Scripts" begin
    cases = [
        ("tables" => "squares = [i^2 for i in 1:10]\nnames = sort([\"pear\", \"apple\"])\nd = Dict(\"a\" => 1)\nprintln(sum(squares), \" \", names, \" \", d[\"a\"])\n", String[], "385 [\"apple\", \"pear\"] 1\n", 0),
        ("ARGS" => "println(length(ARGS), \" \", ARGS)\n", ["x", "y"], "2 [\"x\", \"y\"]\n", 0),
        ("locals in loops" => "total = 0.0\nfor i in 1:4\n    global total += i / 2\nend\nprintln(total)\nname = \"w\"\nname = name * \"!\"\nprintln(name)\n", String[], "5.0\nw!\n", 0),
        ("soft scope" => "total = 0\nfor i in 1:3\n    total += i\nend\nprintln(total)\n", String[], "6\n", 0),
        ("shared variable" => "count = 0\nbump() = global count += 1\nfor _ in 1:3\n    bump()\nend\nprintln(count)\n", String[], "3\n", 0),
        ("struct and functions" => "struct P; x::Int; y::Int; end\nnorm1(p::P) = abs(p.x) + abs(p.y)\np = P(3, -4)\nprintln(norm1(p))\n", String[], "7\n", 0),
        ("main" => "function main(args)\n    println(\"n = \", length(args))\n    return 4\nend\n@main\n", ["a", "b"], "n = 2\n", 4),
        ("exit" => "println(\"one\")\nlength(ARGS) > 0 && exit(5)\nprintln(\"two\")\n", ["x"], "one\n", 5),
        ("compile time" => "x = 5\n@comptime y = x * 2\nprintln(y)\n", String[], "10\n", 0),
        ("runtime marker" => "@runtime z = length(ARGS)\nprintln(z)\n", ["a"], "1\n", 0),
    ]
    for ((name, code), args, expected, status) in cases
        @testset "$name" begin
            out, code_, err = script_run(code, args)
            @test out == expected
            @test code_ == status
        end
    end

    @testset "include" begin
        dir = mktempdir()
        write(joinpath(dir, "inc.jl"), "helper(x) = x * 2\nconst SCALE = 3\n")
        write(joinpath(dir, "script.jl"), "include(\"inc.jl\")\nprintln(helper(SCALE))\n")
        exe = compile_script(joinpath(dir, "script.jl"), dir, "included")
        @test readchomp(`$exe`) == "6"
    end

    @testset "what is refused" begin
        @test_throws ArgumentError compile_script_string("total = 0\nfor i in 1:3\n    total += i\nend\nprintln(total)\n", mktempdir(); scope = :hard)
        @test_throws ArgumentError compile_script_string("1\n", mktempdir(); scope = :loose)
        @test_throws ArgumentError compile_script_string("n = 1\nf() = n\nprintln(f())\n", mktempdir(); globals = :error)
        @test_throws ArgumentError compile_script_string("println(1)\n@comptime y = z\n", mktempdir())
        @test_throws ArgumentError compile_script_string("x = (1\n", mktempdir())
    end
end
