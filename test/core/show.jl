# `show` of containers, types and structs (src/show.jl): the output of the compiled program is exactly that of
# Julia, and the strings that are made when compiling are what Base makes.

struct ShowPt; x::Int; y::Float64; end
struct ShowBox{T}; v::T; end
StaticRuntime.add_show_candidates!(ShowPt, Tuple{Int,Float64})

@testset "Basic `show` and `repr`" begin
    S = StaticRuntime
    # (the output is compared with that of Julia by `static_status`)
    cases = [
        "show String/Char" => @opaque(() -> (show("a \"quoted\"\n string"); show('x'); show('\n'); show('λ'); println(); 1)),
        "show escapes"     => @opaque(() -> (show("tab\there \u00e9 \u2200 \e"); println(); 1)),
        "show unprintable" => @opaque(() -> (show("a\u200bb\ue000\u00ad\U0001f600\u0378"); println(); 1)),
        "@show String"     => () -> (s = "abc"; @show s; c = 'z'; @show c; 1),
        "Vector{Int}"      => () -> (println([1, 2, 3]); 1),
        "empty Vector"     => () -> (println(Int[]); println(Float64[]); println(String[]); 1),
        "Vector{Bool}"     => () -> (println([true, false]); 1),
        "Vector{String}"   => () -> (println(["a", "b\n"]); 1),
        "Vector{Symbol}"   => () -> (println([:a, :bc]); 1),
        "Vector{Char}"     => () -> (println(['a', '\'']); 1),
        "Vector{UInt8}"    => () -> (println(UInt8[1, 255]); 1),
        "Vector{Float32}"  => () -> (println(Float32[1.5, 2]); 1),
        "nested"           => () -> (println([[1, 2], [3]]); 1),
        "Vector{Any}"      => () -> (println(Any[1, "a", 2.5, :s, nothing, 'c', true]); 1),
        "nested Any"       => () -> (println(Any[1, Any["a", Any[2]]]); 1),
        "Vector of tuples" => () -> (println([(1, 2.5), (3, 4.5)]); 1),
        "tuples"           => () -> (println((1,)); println(()); println((1, "a", (2.5, 'c'))); 1),
        "Pair"             => () -> (println(1 => 2); println("a" => [1]); 1),
        "types"            => () -> (println(Int); println(Vector{Float64}); println(Pair{Int,String}); println(Union{Int,Nothing}); 1),
        "struct"           => () -> (println(ShowPt(1, 2.0)); 1),
        "struct in Any"    => () -> (println(Any[ShowPt(1, 2.0), (3, 4.5)]); 1),
        "parametric"       => () -> (println(1 => ShowBox(2)); 1),
        "Dict Int"         => () -> (println(Dict(1 => 2, 3 => 4)); 1),
        "Dict String"      => () -> (println(Dict("a" => 1, "b" => 2)); 1),
        "Dict Symbol"      => () -> (println(Dict(:a => 1.5)); 1),
        "Dict of vectors"  => () -> (println(Dict(1 => [1, 2])); 1),
        "empty Dict"       => () -> (println(Dict{Int,Int}()); println(Dict{String,Any}()); 1),
        "Dict with Any"    => () -> (d = Dict{Int,Any}(); d[1] = "a"; d[2] = 2.5; println(d); 1),
        "Set Int"          => () -> (println(Set([1, 2, 3])); 1),
        "Set String"       => () -> (println(Set(["a", "b"])); 1),
        "Set Float32"      => () -> (println(Set(Float32[1.5])); 1),
        "empty Set"        => () -> (println(Set{Int}()); 1),
        "Set in Vector"    => () -> (println([Set([1])]); 1),
        "repr Dict"        => () -> length(repr(Dict(1 => 2)) * repr(Set([1]))),
        "repr"             => () -> length(repr([1, 2]) * repr(Any[1, "a"]) * repr((1, 'c'))),
    ]
    check_cases(cases)
end

# Strings that are made when compiling
@testset "Compile-time strings" begin
    S = StaticRuntime
    @test S.host_string(show, Int) == "Int64"
    @test S.host_string(show, Vector{Float64}) == "Vector{Float64}"
    @test S.host_string(show, ShowPt) == "ShowPt"       # no `Main.`, as when Julia shows it to a stream
    @test S.host_string(print, Pair{Int,ShowPt}) == "Pair{Int64, ShowPt}"
    # `typeinfo_prefix` (the prefix that Base makes from the context): for each of the types of containers
    for x in ([1], Int[], Float64[], Any[1], Any[], String[], [(1, 2)], Union{Int,Nothing}[1], [ShowPt(1, 2.0)], [UInt8(1)])
        expected = Base.typeinfo_prefix(IOContext(IOBuffer()), x)
        got = S.typeinfo_prefix_static(Any, x)
        @test got == expected
    end
    # with a context that knows the type of the elements
    @test S.typeinfo_prefix_static(Vector{Int}, [1]) == Base.typeinfo_prefix(IOContext(IOBuffer(), :typeinfo => Vector{Int}), [1])
    @test S.typeinfo_prefix_static(Vector{Any}, Any[1]) == Base.typeinfo_prefix(IOContext(IOBuffer(), :typeinfo => Vector{Any}), Any[1])
end

# `show` of arrays of more than one dimension (`println(A)`, `repr(A)`, `string(A)`, "$A"), which is Base's own: its code for matrices makes the matrix a value of the
# type `Any` for the compiler (`inferencebarrier`), and gets the type of the elements from the `IOContext` (`:typeinfo`), which are what the methods in `show.jl`
# change. What is written is compared with what Julia writes.

struct ArrPoint; x::Int; y::Int; end
Base.show(io::IO, p::ArrPoint) = print(io, "P(", p.x, ",", p.y, ")")

@testset "`show` of arrays of more than one dimension" begin
    check_cases([
        "int"             => () -> (println([1 2; 3 4]); 0),
        "float64"         => () -> (println([1.5 2.0; 3.0 4.25]); 0),
        "float32"         => () -> (println(Float32[1.5 2.0; 3.0 4.25]); 0),  # (the type of the elements is in the context: no `f0`)
        "string"          => () -> (println(["a" "bc"; "d" "e"]); 0),
        "bool"            => () -> (println([true false; false true]); 0),
        "char"            => () -> (println(['a' 'b'; 'c' 'd']); 0),
        "symbol"          => () -> (println([:a :b; :c :d]); 0),
        "any"             => () -> (println(Any[1 "a"; 2.5 :s]); 0),
        "union"           => () -> (println(Union{Nothing,Int}[1 nothing; 3 4]); 0),
        "complex"         => () -> (println([1+2im 3-1im; 0im 1im]); 0),
        "rational"        => () -> (println([1//2 3//4; 1//1 2//3]); 0),
        "shapes"          => () -> (println(reshape([7], 1, 1)); println([1 2 3]); println(reshape([1, 2, 3], 3, 1)); 0),
        "empty"           => () -> (println(zeros(0, 3)); println(Matrix{Int}(undef, 0, 0)); 0),
        "3d"              => () -> (println(reshape(1:8, 2, 2, 2)); println(reshape(collect(1.0:8.0), 2, 2, 2)); 0),
        "4d"              => () -> (println(reshape(1:16, 2, 2, 2, 2)); 0),
        "bitmatrix"       => () -> (println(BitMatrix([true false; false true])); 0),
        "wrappers"        => () -> (println(reshape(1:6, 2, 3)); println(transpose([1 2; 3 4])); println([1.0 2.0; 3.0 4.0]'); println(view([1 2 3; 4 5 6], 1:2, 2:3)); 0),
        "linalg"          => () -> (println(Symmetric([1 2; 2 3])); println(Diagonal([1, 2])); println(Matrix(1.0I, 2, 2)); 0),
        "repr"            => () -> (println(repr([1 2; 3 4])); println(string([1.5 2.0; 3.0 4.0])); println("A = $([1 2; 3 4])"); 0),
        "nested"          => () -> (println([[1 2; 3 4], [5 6; 7 8]]); println(([1 2; 3 4], 1)); println(Dict(:a => [1 2; 3 4])); 0),
        "zeros"           => () -> (println(zeros(2, 2)); println(ones(Int, 2, 3)); 0),
        "zero dim"        => () -> (println(fill(5)); 0),
        "struct elements" => () -> (println([ArrPoint(1, 2) ArrPoint(3, 4); ArrPoint(5, 6) ArrPoint(7, 8)]); 0),
        "sizes"           => () -> (println(rand(3, 3) |> size); println(size(zeros(2, 3, 4))); 0),
    ])
end

# `text/plain` (what `display` writes, and `show(io, MIME"text/plain"(), x)`), and the properties of the context (`IOContext(io, :compact => true)`, `:limit`, `:displaysize`), which
# are Base's own code running on the streams of `context.jl` (the properties are in the type of the stream, so they are known when compiling).
# What is written is compared with what Julia writes.

const PL_TP = MIME"text/plain"()
struct PlPoint; x::Int; y::Float64; end
pl_text(x) = (println(sprint(show, PL_TP, x)); 0)
pl_nl() = print(STDOUT, "\n")


# the properties of a context, written as Julia does (to the standard output of libc, with the same stream in Julia and in the program)

@testset "`text/plain` and the properties of a context" begin
    # (the properties of a context are in the type of its stream, so asking for them is done when compiling: what the three of them ask has no program left)
    check_cases([
        "matrix int"            => () -> pl_text([1 2; 3 4]),
        "matrix float"          => () -> pl_text([1.5 2.0; 3.0 4.25]),
        "matrix compact floats" => () -> pl_text([0.1+0.2 1/3; 2/3 1.0]),  # (a matrix is shown with `:compact`: `0.3`)
        "matrix any"            => () -> pl_text(Any[1 "a"; 2.5 :s]),
        "matrix complex"        => () -> pl_text([1+2im 3-1im; 0im 1im]),
        "matrix complex float"  => () -> pl_text([1.0e-5+2.5e10im 3.0-1.0e-3im; 1.5+2.5im 0.0im]),
        "matrix wide"           => () -> pl_text([1 1000000; -5 12345]),
        "matrix exponents"      => () -> pl_text([-1.5e-10 2.0; 1e20 -0.25]),
        "column"                => () -> pl_text(reshape([1.5, 22.25, 3.0], 3, 1)),
        "empty"                 => () -> (pl_text(zeros(0, 3)); pl_text(Int[]); pl_text(Matrix{Float64}(undef, 0, 0)); 0),
        "3d"                    => () -> pl_text(reshape(1:8, 2, 2, 2)),
        "vector int"            => () -> pl_text([1, 2, 3]),
        "vector float"          => () -> pl_text([1.5, 2.0, 0.1 + 0.2]),
        "vector string"         => () -> pl_text(["a", "bc"]),
        "vector any"            => () -> pl_text(Any[1, "a", 2.5]),
        "range"                 => () -> (pl_text(1:5); pl_text(0.5:0.5:2.0); 0),
        "dict"                  => () -> (pl_text(Dict(:a => 1, :b => 2)); pl_text(Dict("x" => 1.5)); 0),
        "set"                   => () -> pl_text(Set([1, 2, 3])),
        "scalars"               => () -> (pl_text(3.5); pl_text("str"); pl_text(nothing); pl_text((1, "a")); pl_text(:a => 1); pl_text('c'); pl_text(true); 0),
        "struct"                => () -> pl_text(PlPoint(1, 2.5)),
        "wrappers"              => () -> (pl_text([1 2; 3 4]'); pl_text(view([1 2 3; 4 5 6], 1:2, 2:3)); pl_text(reshape(1:6, 2, 3)); 0),
        "chars"                 => () -> (pl_text('a'); pl_text('é'); pl_text('1'); pl_text(' '); pl_text('日'); pl_text('\n'); 0),
        "sprint any"            => () -> (x = Base.inferencebarrier(1)::Any; println(sprint(show, x)); y = Base.inferencebarrier("s")::Any; println(sprint(show, y)); 0),
        "ctx compact"           => () -> (show(IOContext(STDOUT, :compact => true), 0.1 + 0.2); pl_nl(); show(IOContext(STDOUT, :compact => true), [0.1 + 0.2, 1/3]); pl_nl();
              show(IOContext(STDOUT, :compact => true), [0.1+0.2 1/3; 2/3 1.0]); pl_nl(); show(IOContext(STDOUT, :compact => true), 0.1 + 0.2im); pl_nl(); 0),
        "ctx limit vector"      => () -> (show(IOContext(STDOUT, :limit => true), collect(1:30)); pl_nl(); show(IOContext(STDOUT, :limit => true), collect(1:5)); pl_nl();
              show(IOContext(STDOUT, :limit => true), ["abc$i" for i in 1:30]); pl_nl(); 0),
        "ctx limit matrix"      => () -> (show(IOContext(STDOUT, :limit => true), reshape(1:100, 10, 10)); pl_nl(); show(IOContext(STDOUT, :limit => true), reshape(1:1000, 10, 10, 10)); pl_nl(); 0),
        "ctx limit others"      => () -> (show(IOContext(STDOUT, :limit => true), Dict(i => i for i in 1:5)); pl_nl(); show(IOContext(STDOUT, :limit => true), Set(1:5)); pl_nl();
              show(IOContext(STDOUT, :limit => true), 1:100); pl_nl(); show(IOContext(STDOUT, :limit => true), "a"^50); pl_nl(); 0),
        "ctx two"               => () -> (show(IOContext(STDOUT, :compact => true, :limit => true), collect(0.1:0.1:3.0)); pl_nl(); 0),
        "ctx plain limit"       => () -> (show(IOContext(STDOUT, :limit => true, :displaysize => (24, 80)), PL_TP, reshape(1:100, 10, 10)); pl_nl();
              show(IOContext(STDOUT, :limit => true, :displaysize => (10, 80)), PL_TP, collect(1:100)); pl_nl();
              show(IOContext(STDOUT, :limit => true, :displaysize => (24, 60)), PL_TP, reshape(collect(1.5:1.0:60.5), 3, 20)); pl_nl(); 0),
        "ctx query"             => () -> (io = IOContext(STDOUT, :limit => true, :compact => false); (get(io, :limit, false) ? 1 : 0) + (get(io, :compact, true) ? 10 : 0) +
              (haskey(io, :limit) ? 100 : 0) + (haskey(io, :color) ? 1000 : 0) + (io[:limit] ? 10000 : 0)),
        "ctx nested"            => () -> (io = IOContext(IOContext(STDOUT, :compact => true), :limit => true, :compact => false); (get(io, :limit, false) ? 1 : 0) + (get(io, :compact, true) ? 10 : 0)),
        "ctx displaysize"       => () -> (io = IOContext(STDOUT, :displaysize => (30, 100)); d = displaysize(io); d[1] + d[2]),
    ]; folded_ok = ("ctx query", "ctx nested", "ctx displaysize"))
end

# structured matrices (the module `LinearAlgebra` is loaded before this package in the tests, so its types are written without the module, as Julia does: when a module is loaded
# after the package, its types are written with the module, see `show.jl`)
pl_structured() = (pl_text(Diagonal([1, 2, 3])); pl_text(UpperTriangular([1 2 3; 4 5 6; 7 8 9])); pl_text(LowerTriangular([1.5 2.0; 3.0 4.0])); pl_text(Tridiagonal([1, 2], [3, 4, 5], [6, 7]));
                   pl_text(Symmetric([1 2; 2 3])); pl_text(Hermitian([1.0 2.0im; -2.0im 3.0])); 0)
@testset "Structured matrices" begin
    expected = join(sprint(show, PL_TP, x) * "\n" for x in Any[Diagonal([1, 2, 3]), UpperTriangular([1 2 3; 4 5 6; 7 8 9]), LowerTriangular([1.5 2.0; 3.0 4.0]),
                                                               Tridiagonal([1, 2], [3, 4, 5], [6, 7]), Symmetric([1 2; 2 3]), Hermitian([1.0 2.0im; -2.0im 3.0])]) * "0\n"
    @test compiled_stdout(pl_structured) == expected
end

# `display(x)` of Julia writes to the terminal that Julia was started with, which a test can't capture: the output of the program is compared with the `text/plain` text instead
pl_display_values() = (display([1 2; 3 4]); display([1, 2, 3]); display(3); display("a"); display(1.5); display(:s); display(nothing); display(Dict(:a => 1)); display(1:3); 0)
pl_display_floats() = (display([1.5 2.0; 3.0 0.1+0.2]); display(Any[1, "a", 2.5]); display(reshape(1:8, 2, 2, 2)); 0)
@testset "Display" begin
    expected = join(sprint(show, PL_TP, x) * "\n" for x in Any[[1 2; 3 4], [1, 2, 3], 3, "a", 1.5, :s, nothing, Dict(:a => 1), 1:3]) * "0\n"
    @test compiled_stdout(pl_display_values) == expected
    expected = join(sprint(show, PL_TP, x) * "\n" for x in Any[[1.5 2.0; 3.0 0.1+0.2], Any[1, "a", 2.5], reshape(1:8, 2, 2, 2)]) * "0\n"
    @test compiled_stdout(pl_display_floats) == expected
end


# # the keyword `context` of `sprint` with a pair that is written in the call: its value is not known to the compiler inside the method of `sprint` (not yet supported for the show of an array)
# pl_sprint_context_vector() = (println(sprint(show, [1, 2, 3]; context = :compact => true)); 0)
# @testset "sprint with a context in the call" begin
#     @test_broken static_status(pl_sprint_context_vector)[1] == :ok
# end

# types and values that are not supported are rejected when compiling, or are an error when run (not wrong output)
@testset "Unsupported" begin
    @test static_status(() -> (println(Any[Base.inferencebarrier(ShowBox(1))]); 1))[1] == :runtime_error # not in the candidates, and what is in the list is not known when compiling
    @test static_status(() -> (println(Any[ShowBox(1)]); 1))[1] == :ok # (the types that a list holds are those that the program puts in it: see slots.jl)
    # (a symbol that is not an ASCII identifier is written as Julia writes it if the binary has it; one that the program makes is an error unless
    # it is certainly not an identifier or an operator: see `symbols.jl`)
    @test static_status(() -> (println(Any[Symbol("+")]); 1))[1] == :ok
    @test static_status(() -> (println(Any[Symbol("a+" * Base.inferencebarrier("b"))]); 1))[1] == :runtime_error # made by the program, and not clearly an operator or not
    @test static_status(() -> (println(Any[Base.inferencebarrier(Dict(1 => 2))]); 1))[1] == :runtime_error # not in the candidates
    @test static_status(() -> (println(Any[Dict(1 => 2)]); 1))[1] == :ok
    @test static_status(() -> (println(Base.inferencebarrier(Any[1])); 1))[1] == :runtime_error # (a call with an `Any`: over the types that are registered, which have not `Vector{Any}`)
end

# the stream types write like the streams of libc, and `sprint` makes the same text as Julia's
@testset "Streams" begin
    S = StaticRuntime
    io = S.BufIO(IOBuffer())
    show(io, [1, 2, 3]); show(io, (1, "a")); show(io, Any[1, :a])
    @test String(take!(io.buf)) == sprint(show, [1, 2, 3]) * sprint(show, (1, "a")) * sprint(show, Any[1, :a])
    @test S.typeinfo_io(io, Int) isa IO
    @test get(S.typeinfo_io(io, Int), :typeinfo, Any) === Int
    @test get(io, :typeinfo, Any) === Any
end