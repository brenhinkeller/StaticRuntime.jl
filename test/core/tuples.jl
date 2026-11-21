# Tuples of elements of different types, which are indexed and iterated with an index that is not known when compiling (`for x in t`, `iterate`, `collect`, and
# `Dict(:a => 1, :b => "x")`, which goes through the pairs as a tuple): the type of the element depends on the index.

tu_p(x) = (println(x); 0)
const TU_HET = (1, "ab", 2.5, :sym, 'c')
const TU_PAIRS = (:a => 1, :b => "x", :c => 2.5)

@testset "Tuples of different types" begin
    tu_for_print() = (for x in (1, "a", 2.5); println(x); end; 0)
    tu_for_lengths() = (n = 0; for x in ("ab", 'c', :sym); n += length(string(x)); end; n)
    tu_for_const() = (n = 0; for x in TU_HET; n += length(string(x)); end; n)
    tu_index_runtime() = (i = Base.inferencebarrier(2)::Int; length(string(TU_HET[i])) + length(string(TU_HET[Base.inferencebarrier(4)::Int])))
    tu_index_bounds() = @opaque((i = Base.inferencebarrier(9)::Int; try; TU_HET[i]; 0; catch e; e isa BoundsError ? 1 : 2; end))
    tu_index_zero() = @opaque((i = Base.inferencebarrier(0)::Int; try; TU_HET[i]; 0; catch e; e isa BoundsError ? 1 : 2; end))
    tu_collect() = length(collect((1, "a", 2.5)))
    tu_collect_values() = (v = collect(TU_HET); length(v) + length(string(v[2])))
    tu_homogeneous() = @opaque((s = 0; for x in (1, 2, 3); s += x; end; s))
    tu_union_field() = @opaque((s = 0; for x in (1, 2.5, 3); s += round(Int, x); end; s))
    tu_map() = sum(length, map(string, TU_HET))
    tu_reverse_first() = (t = (opaque(7), "str", opaque(2.5)); length(string(first(reverse(t)))) + length(t)) # (a tuple of values that are made when the program runs: a constant one is reversed by the compiler)
    tu_zip_same() = @opaque((s = 0; for (a, b) in zip((1, 2), ("x", "yy")); s += a + length(b); end; s))
    tu_in() = @opaque((1 in (1, "a")) + 2 * ("a" in (1, "a")) + 4 * (:q in (1, "a")))

    tuple_cases = [tu_for_print, tu_for_lengths, tu_for_const, tu_index_runtime, tu_index_bounds, tu_index_zero, 
        tu_collect, tu_collect_values, tu_homogeneous, tu_union_field, tu_map, tu_reverse_first, tu_zip_same, tu_in,]
        
    check_cases(tuple_cases)
end

# what inference finds for them is what Julia finds (the type of the elements is not lost)
# `fieldtype(T, i)` of a type that is known by an index (or a name) that is not: Julia reads the field types of the type
# object, which a type in the binary does not have (it was `String` for every field, silently); and `show` of a
# `NamedTuple`, which compares the type of each field with it, and writes the names as Base does (`Meta.isidentifier`)
@noinline ft_index(i) = i + opaque(0)
@testset "Field types by an index that is not known" begin
    check_cases([
        "fieldtype by an index"     => () -> (T = typeof((opaque(1), "x", 2.0)); for i in 1:3; println(fieldtype(T, ft_index(i))); end; 0),
        "fieldtype by a name"       => () -> (T = typeof((a = opaque(1), b = "x")); for s in (:a, :b); println(fieldtype(T, Symbol(string(s, opaque(0) == 0 ? "" : "z")))); end; 0),
        "show of a NamedTuple"      => () -> (println((a = opaque(1), b = "x", c = 2.0)); 0),
        "show after merge"          => () -> (println(merge((a = opaque(1), b = "x"), (c = 2.0,))); 0),
        "names that are not plain"  => () -> (println((α = opaque(1), var"a b" = 2, var"true" = 3)); 0),
        "isidentifier"              => () -> (println(Base.isidentifier(string("x", opaque(1))), Base.isidentifier(string(opaque(1), "x")), Base.isidentifier(string("δ", opaque(1)))); 0),
    ])
end

@testset "Types of tuple elements" begin
    t_iter(i::Int) = iterate(TU_HET, i)
    ours = last(first(StaticRuntime.static_code_typed(t_iter, (Int,))))
    @test ours == only(Base.return_types(t_iter, (Int,)))
    @test ours != Any
end

@testset "Iterating a tuple of different types" begin
    check_cases([
        "iterating a mixed tuple" => () -> (s = 0; for x in (1, 2.5, 3); s += x; end; println(s); 0),
    "tuple/loop" => @opaque(() -> (s = 0; for x in (1, 2, 3); s += x; end; s)),
    ])
end

# `(; label, value)` with a `value` of the type `Any`: its type is made of the type of the tuple, which is the type of the values when the program runs (StyledStrings makes its annotations this way)
tu_any_value() = Base.inferencebarrier(time_ns() >> 63 == 0 ? :red : 1)
tu_make(label::Symbol, value) = (; label, value)
tu_make3(r, label::Symbol, value) = (; region = r, label, value)
@testset "NamedTuples made of a value of the type Any" begin
    check_cases([
        "two fields"      => () -> (a = tu_make(:face, tu_any_value()); a.label === :face && a.value === :red ? 1 : 0),
        "three fields"    => () -> (a = tu_make3(2:5, :face, tu_any_value()); first(a.region) + length(a.region) + (a.value === :red ? 10 : 0)),
        "in a Vector"     => () -> (v = Vector{@NamedTuple{label::Symbol,value::Any}}(); push!(v, tu_make(:a, tu_any_value())); push!(v, tu_make(:b, 3)); length(v) + (v[2].value === 3 ? 10 : 0)),
        "a mix"           => () -> (a = tu_make(:x, opaque("text")); b = tu_make(:y, opaque(2.5)); ncodeunits(a.value) + b.value),
    ])
end


@testset "Dicts of different value types" begin
    # `Dict` of pairs of different types
    di_mixed() = (d = Dict(:a => 1, :b => "x"); length(d))
    di_mixed_numbers() = (d = Dict(:a => 1, :b => 2.5); length(d))
    di_typed_any() = (d = Dict{String,Any}("a" => 1, "b" => "x"); length(d))
    di_any_any() = (d = Dict{Any,Any}(1 => "a", "b" => 2.0); length(d))
    di_many_types() = (d = Dict("a" => 1, "b" => "x", "c" => [1, 2], "d" => (1, 2)); length(d))
    di_lookup() = (d = Dict(:a => 1, :b => "x", :c => 2.5); d[:a] + 1 + length(d[:b]) + round(Int, d[:c]))
    di_haskey_get() = (d = Dict("a" => 1, "b" => "x"); haskey(d, "a") + 2 * haskey(d, "z") + 4 * (get(d, "z", 7) == 7))
    di_iterate() = (d = Dict(:a => 1, :b => "x"); n = 0; for (k, v) in d; n += length(string(k)) + length(string(v)); end; n)
    di_print() = (println(Dict(:a => 1, :b => "x")); 0)
    di_repr() = (println(repr(Dict(:a => 1, :b => "x", :c => 2.5))); 0)
    # (the order of iteration depends on the size of the table, which depends on how the Dict is made: with `sizehint!` for one type of pair, growing for the rest)
    di_order_same() = (println(Dict("a$i" => i for i in 1:3)); println(Dict("a1" => 1, "a2" => 2, "a3" => 3, "a4" => 4, "a5" => 5, "a6" => 6, "a7" => 7, "a8" => 8, "a9" => 9, "a10" => 10, "a11" => 11, "a12" => 12)); 0)
    di_order_mixed() = (println(Dict("a1" => 1, "a2" => "x", "a3" => 3, "a4" => "y", "a5" => 5, "a6" => "z", "a7" => 7, "a8" => "w", "a9" => 9, "a10" => "v", "a11" => 11, "a12" => "u")); 0)
    di_order_widening() = (println(Dict(:a => 1, :b => 2, :c => 3.5, :d => 4, :e => 5, :f => "s", :g => 7, :h => 8, :i => 9)); 0)
    di_types() = (println(typeof(Dict(:a => 1, :b => 2.5))); println(typeof(Dict(:a => 1, :b => "x"))); println(typeof(Dict(:a => 1, :b => "x", :c => 2.5)));
                println(typeof(Dict(1 => 1, 2.0 => 2))); println(typeof(Dict("a" => 1, "b" => nothing))); println(typeof(Dict("a" => 1, "b" => missing))); 0)
    di_empty_and_single() = (println(typeof(Dict())); println(Dict(:a => 1)); println(typeof(Dict(1 => "a", 2 => "b"))); 0)
    di_merge() = (d = merge(Dict(:a => 1), Dict(:b => "x")); length(d))
    di_setindex_mixed() = @opaque((d = Dict{Symbol,Any}(); d[:a] = 1; d[:b] = "x"; d[:c] = 2.5; length(d)))
    di_from_pairs_const() = @opaque((d = Dict(TU_PAIRS...); length(d) + length(d[:b])))
    di_vector_of_tuples() = (d = Dict([(1, "a"), (2, "b")]); length(d))
    di_generator() = @opaque((d = Dict(i => i^2 for i in 1:5); length(d)))
    di_zip() = (d = Dict(zip([1, 2, 3], ["a", "b", "c"])); length(d))
    di_pairs_namedtuple() = @opaque((d = Dict(pairs((a = 1, b = 2))); length(d)))

    dict_cases = [di_mixed, di_mixed_numbers, di_typed_any, di_any_any, di_many_types, di_lookup, di_haskey_get, di_iterate, di_print, di_repr, di_order_same, di_order_mixed, 
        di_order_widening, di_types, di_empty_and_single, di_merge, di_setindex_mixed, di_from_pairs_const, di_vector_of_tuples, di_generator, di_zip, di_pairs_namedtuple]
    
    check_cases(dict_cases)
end

# `eltype` of a tuple type that has types that are not all one: it is the join of them (`Any` for `String` and `Int`), and so is that of the `pairs` of a `NamedTuple` (inference did not find that with the limit that we split a union in)
@testset "`eltype` of the types of a tuple" begin
    check_cases([
        "eltype of a mixed NamedTuple" => () -> length(string(eltype(typeof((; a = "x", b = "y", c = 1 + opaque(0), d = 2))))),
        "eltype of pairs, mixed"       => () -> length(string(eltype(pairs((; a = "x", b = "y", c = 1 + opaque(0)))))),
        "eltype of pairs, one type"    => () -> length(string(eltype(pairs((; a = 1 + opaque(0), b = 2))))),
        "pairs of mixed, iterated"     => () -> (s = 0; for (k, v) in pairs((; a = "xx", b = "y", c = 5 + opaque(0))); s += v isa String ? length(v) : v; end; s),
    ]; batch = false)
end
# A tuple that has an element of a few types (`Tuple{Union{Vector{Float64},Vector{ComplexF64}},Int}`) is made and read as one of the tuples that it is made of (see `split_tuple` in src/inference/dispatch.jl):
# returned by a function that is not inlined, stored in an array, and made by `enumerate` (Julia makes these with the types of the values, which an executable can't)
@noinline union_tuple(n::Int) = (n > 0 ? [1.0] : [1.0im], n)
const UNION_TUPLE_ANY = Any[1, 2.5]
@testset "Tuples that have an element of a few types" begin
    check_cases([
        "returned by a function that is not inlined" => () -> (p = union_tuple(opaque(1)); p[2] * 10 + length(p[1])),
        "stored in an array"                         => () -> (v = [union_tuple(opaque(1)), union_tuple(opaque(-1))]; length(v[1][1]) * 10 + v[2][2]),
        "made by enumerate"                          => () -> (s = 0.0; for (i, x) in enumerate(UNION_TUPLE_ANY[1:opaque(2)]); s += i * (x::Union{Int,Float64}); end; s),
        "a pair of values of two types"              => () -> (t = (opaque(1) > 1 ? 1 : 2.5, "s"); println(t[1] + 1, " ", t[2]); 0),
    ])
end
