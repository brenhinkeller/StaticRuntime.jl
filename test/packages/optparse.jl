# OptParse: command-line parsers made of parsers (`@parser`, `record`, `option`, `optional`, `command`, `runparse`). Programs compile with its `juliac` preference (set in `test/Project.toml`),
# the code of it that works without a runtime. Each program parses arguments that are only known when it runs, and has to print what Julia prints, errors and help (which go to the
# standard error) included.

using OptParse

@parser struct OPConfig
    @description "Development server"
    "Hostname to bind"
    host = default(option("--host", str("HOST")), "localhost")
    "TCP port"
    port = default(option("-p", "--port", integer("PORT"; min = 1, max = 65535)), 8080)
    "Enable verbose logging"
    verbose = flag("-v", "--verbose")
end

# (optional arguments, a choice, repeated options, a positional argument: the value of an optional one that is absent is `nothing`)
@parser struct OPTool
    @description "A tool"
    "Input file"
    input = arg(str("FILE"))
    "Output file"
    output = optional(option("-o", "--output", str("FILE")))
    "Mode"
    mode = default(option("--mode", choice("MODE", ["fast", "safe"])), "safe")
    "Level"
    level = optional(option("-l", "--level", integer("N"; min = 0)))
    "Extra files"
    extra = many(option("-x", "--extra", str("FILE")))
    verbose = flag("-v", "--verbose")
    "Ratio"
    ratio = default(option("--ratio", flt64("R")), 0.5)
end

@parser struct OPGreet
    @description "Greet someone"
    "Name to greet"
    name = arg(str("NAME"))
    "Shout it"
    loud = flag("-l", "--loud")
end

@parser struct OPAdd
    @description "Add numbers"
    "Numbers to add"
    numbers = many1(arg(integer("NUMBER")))
end

const OP_CLI = or(command("greet", lift(OPGreet)), command("add", lift(OPAdd)))
const OP_RECORD = record(; o = optional(option("-o", str("F"))), p = default(option("-p", str("F")), "d"))

op_show(c::OPConfig) = (println(c.host, " ", c.port, " ", c.verbose); 0)
op_show(::Nothing) = 2
function op_show(c::OPTool)
    println("input=", c.input)
    println("output=", c.output === nothing ? "none" : c.output)
    println("mode=", c.mode)
    println("level=", c.level === nothing ? "none" : c.level)
    println("extra=", c.extra)
    println("verbose=", c.verbose, " ratio=", c.ratio)
    return 0
end
op_show(r::OPGreet) = (println(r.loud ? uppercase("hello, " * r.name) : "Hello, " * r.name); 0)
op_show(r::OPAdd) = (println("Your result is ", sum(r.numbers)); 0)

# (the first argument is made opaque, so that the parse is a computation of the program, and not of the compiler)
op_args(first::String, rest::String...) = String[opaque(first), rest...]

@testset "OptParse" begin
    check_cases([
        "defaults"                 => () -> op_show(optparse(OPConfig, op_args("--host", "localhost"))),
        "port and verbose"         => () -> op_show(optparse(OPConfig, op_args("--port", "9000", "-v"))),
        "port out of range"        => () -> op_show(optparse(OPConfig, op_args("--port", "99999"))),
        "port not a number"        => () -> op_show(optparse(OPConfig, op_args("--port", "abc"))),
        "unknown option"           => () -> op_show(optparse(OPConfig, op_args("--bogus"))),
        "option without a value"   => () -> op_show(optparse(OPConfig, op_args("--port"))),
        "tool, only the input"     => () -> op_show(optparse(OPTool, op_args("a.txt"))),
        "tool, an optional given"  => () -> op_show(optparse(OPTool, op_args("a.txt", "-o", "out"))),
        "tool, long forms"         => () -> op_show(optparse(OPTool, op_args("a.txt", "--output=out2", "--mode", "fast"))),
        "tool, optional int"       => () -> op_show(optparse(OPTool, op_args("a.txt", "-l", "3", "-v"))),
        "tool, repeated option"    => () -> op_show(optparse(OPTool, op_args("a.txt", "-x", "e1", "-x", "e2", "--ratio", "1.25"))),
        "tool, flag first"         => () -> op_show(optparse(OPTool, op_args("-v", "a.txt", "--level=7"))),
        "tool, no input"           => () -> op_show(optparse(OPTool, String[])),
        "tool, a bad choice"       => () -> op_show(optparse(OPTool, op_args("a.txt", "--mode", "bogus"))),
        "tool, a number too small" => () -> op_show(optparse(OPTool, op_args("a.txt", "-l", "-1"))),
        "tool, two inputs"         => () -> op_show(optparse(OPTool, op_args("a.txt", "b.txt"))),
        "record, optional absent"  => () -> (r = optparse(OP_RECORD, String[opaque("-p"), "x"]); println(r.o === nothing ? "none" : r.o, " ", r.p); 0),
        "record, optional given"   => () -> (r = optparse(OP_RECORD, String[opaque("-o"), "v"]); println(r.o === nothing ? "none" : r.o, " ", r.p); 0),
        "subcommand greet"         => () -> op_show(runparse(OP_CLI, op_args("greet", "Ada"); progname = "demo")),
        "subcommand add"           => () -> op_show(runparse(OP_CLI, op_args("add", "2", "3", "4"); progname = "demo")),
        "subcommand with a flag"   => () -> op_show(runparse(OP_CLI, op_args("greet", "Ada", "-l"); progname = "demo")),
        "unknown subcommand"       => () -> op_show(runparse(OP_CLI, op_args("bogus"); progname = "demo")),
        "no arguments, help"       => () -> op_show(runparse(OP_CLI, String[]; progname = "demo")),
        "--help"                   => () -> op_show(runparse(OP_CLI, op_args("--help"); progname = "demo")),
        "help of a subcommand"     => () -> op_show(runparse(OP_CLI, op_args("greet", "--help"); progname = "demo")),
        "missing subcommand input" => () -> op_show(runparse(OP_CLI, op_args("greet"); progname = "demo")),
    ])
end
