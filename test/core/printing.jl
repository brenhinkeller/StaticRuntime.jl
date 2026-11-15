# `print`, `println`, `show`, `string` and `sprint` of scalars and strings, the standard streams (`STDOUT`, `STDERR`) and `printstyled`: what is written is compared with what Julia writes.
# (`show` of containers, types, structs and arrays, and `text/plain`, are in `show.jl`; `Printf` is in `packages/printf.jl`.)

# the global `stderr` has the abstract type `IO`: a program says `STDERR`
@testset "print and show" begin
    check_cases([
    # printing
    "println Vector Float64" => () -> (println([1.5, 2.0]); 1),
    "string mixed"          => () -> length(string("a", 1, 'b', 2.5)),
    "sprint"                => () -> length(sprint(print, 12345)),
    "stdout"                => () -> (println(stdout, "to stdout"); 1),
    "stderr"                => () -> (println(stderr, "to stderr"); 1),
    "STDOUT"                => () -> (println(STDOUT, "explicit ", 1, ' ', 2.5); print(STDOUT, "x", 'y'); println(STDOUT); 1),
    "STDERR"                => () -> (println(STDERR, "to stderr"); print(STDERR, 1, 2, 3); println(STDERR); 1),
    "STDOUT show"  => @opaque(() -> (show(STDOUT, 12); show(STDOUT, "str"); show(STDOUT, 'c'); println(STDOUT); 1)),
    "STDOUT flush" => @opaque(() -> (print(STDOUT, "a"); flush(STDOUT); print(STDERR, "b"); flush(STDERR); println(STDOUT); 1)),
    "print String vararg"   => () -> (print("a", "b", "c", "d"); println(); println("x", 1, 2, 3, "y"); 1),
    "println nothing"       => () -> (println(); println(nothing); println(missing); 1),
    "println Symbol/Float32" => () -> (println(:sym, ' ', 1.5f0, ' ', 0x1f, ' ', -3); 1),
    "big output"            => () -> (for i in 1:2000; print(i, ' '); end; println(); 1),
    ]; broken = ("stdout", "stderr",))
end

@testset "Functions, `Colon()`, summaries and types written to a buffer" begin
    check_cases([
        "functions and Colon() are written" => () -> (print(sin); print(' '); print(:); print(' '); print(typeof(sin)); print(' '); println((:, identity)); 0),
        "functions and Colon() in a string" => () -> ncodeunits(string(sin, identity, :)),
        "summary of an array"     => () -> (println(summary([1, 2])); println(summary([1.0 2.0])); 0),
        "a type to an IOBuffer"   => () -> (io = IOBuffer(); print(io, Vector{Int}); println(String(take!(io))); 0),
    ])
end

# `printstyled`: the escape sequences when the context of the stream has color, and plain text when it has not (`STDOUT` is as the output of `julia script.jl > file`)
sty_color(name) = Symbol(Base.inferencebarrier(name))
@testset "printstyled and color" begin
    check_cases([
        "no color on STDOUT"       => () -> (printstyled("plain\n"; color = :red, bold = true); printstyled(STDOUT, "plain\n"; color = :blue); 0),
        "a color"                  => () -> (printstyled(IOContext(STDOUT, :color => true), "red\n"; color = :red); 0),
        "bold, underline, blink"   => () -> (printstyled(IOContext(STDOUT, :color => true), "x", 1, '\n'; bold = true, underline = true, blink = true); 0),
        "italic, reverse, hidden"  => () -> (printstyled(IOContext(STDOUT, :color => true), "x\n"; italic = true, reverse = true, hidden = true, color = :light_cyan); 0),
        "a number"                 => () -> (printstyled(IOContext(STDOUT, :color => true), "n\n"; color = 202); printstyled(IOContext(STDOUT, :color => true), "n\n"; color = 300); 0),
        "lines"                    => () -> (printstyled(IOContext(STDOUT, :color => true), "one\n\ntwo\nthree"; color = :green); print(STDOUT, "\n"); 0),
        "a name that is made"      => () -> (printstyled(IOContext(STDOUT, :color => true), "m\n"; color = sty_color("magenta")); printstyled(IOContext(STDOUT, :color => true), "m\n"; color = sty_color("nothing")); 0),
        "the style is the color"   => () -> (printstyled(IOContext(STDOUT, :color => true), "b\n"; color = :bold, bold = true); 0),
        "STDERR"                   => () -> (printstyled(IOContext(STDERR, :color => true), "e\n"; color = :yellow); 0),
        "to a string"              => () -> (s = sprint(io -> printstyled(IOContext(io, :color => true), "s"; color = :red)); println(ncodeunits(s)); 0),
    ])
end
