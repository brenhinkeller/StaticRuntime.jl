# Observables: values that call functions when they are set (`on`, `map`, `onany`), which Makie is built on. The package calls its listeners as functions of the type `Any` (see
# `ext/StaticRuntimeObservablesExt.jl`).

using Observables, StaticArrays

# Observables that are made before the program is compiled, with listeners (as those of a scene of Makie), which are found when compiling: the code that updates each, and each of the listeners, is made for it (see "Code for each object" in
# src/inference/objects.jl), so what one stores in another is known of that one, and not of all the observables of their type (here a pair of the values of two, stored in a third: with one type for all of them, the types of
# the pairs would be pairs of pairs, without end). The other observables hold values of many types.
const OB_X = Observable{Any}(identity)
const OB_Y = Observable{Any}(identity)
const OB_PAIR = Observable{Any}((identity, identity))
const OB_OTHERS = Observable{Any}[Observable{Any}(x) for x in (1, 2.0, "s", :a, 'c', 0x01, Int32(2), 1f0, (1, 2), nothing, missing)]
onany((x, y) -> (OB_PAIR[] = (x, y); nothing), OB_X, OB_Y)
ob_pair() = (OB_X[] = opaque(1) == 1 ? log10 : identity; t = OB_PAIR[]; println(t[1] === log10, " ", t[2] === identity, " ", OB_OTHERS[opaque(3)][] isa String); 0)


@testset "Observables" begin
    check_cases([
        "set and get"  => () -> (o = Observable(opaque(1)); o[] = 5; o[] + 1),
        "on"           => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> n[] += x, o); o[] = 4; n[]),
        "on, twice"    => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> n[] += x, o); on(x -> n[] += 10x, o); o[] = 4; n[]),
        "on, weak not known" => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> n[] += x, o; weak = opaque(1) > 5); o[] = 4; n[]),
        "update"       => () -> (o = Observable(opaque(3)); n = Ref(0); on(x -> n[] += x, o; update = true); n[]),
        "map"          => () -> (o = Observable(opaque(2)); m = map(x -> x * 3, o); o[] = 5; m[]),
        "map, two"     => () -> (a = Observable(opaque(1)); b = Observable(opaque(2)); m = map((x, y) -> x + y, a, b); a[] = 10; m[]),
        "onany"        => () -> (a = Observable(opaque(1)); b = Observable(opaque(2)); n = Ref(0); onany((x, y) -> n[] += x * y, a, b); a[] = 4; n[]),
        "a Float64"    => () -> (o = Observable(Float64(opaque(1))); n = Ref(0.0); on(v -> n[] += v, o); o[] = 3.0; round(Int, n[])),
        "an SVector"   => () -> (o = Observable(SVector(opaque(1), 2)); n = Ref(0); on(v -> n[] += v[1], o); o[] = SVector(3, 4); n[]),
        "no listener"  => () -> (o = Observable(SVector(opaque(1), 2)); o[] = SVector(3, 4); o[][1]),
        "two types"    => () -> (a = Observable(opaque(1)); b = Observable(2.5); n = Ref(0.0); on(x -> n[] += x, a); on(y -> n[] += 10y, b); a[] = 4; b[] = 1.5; round(Int, n[])),
        "a tuple"      => () -> (o = Observable((opaque(1), 2)); n = Ref(0); on(v -> n[] += v[1], o); o[] = (3, 4); n[]),
        "consumed"     => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> (n[] += x; Consume(true)), o); on(x -> n[] += 100x, o); o[] = 4; n[]),
        "not consumed" => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> (n[] += x; Consume(false)), o); on(x -> n[] += 100x, o); o[] = 4; n[]),
        "listeners of other types" => () -> (a = Observable(opaque(1)); b = Observable((opaque(2), 3.5)); n = Ref(0); on(x -> n[] += x, a); on(t -> n[] += 10t[1], b); b[] = (5, 1.0); a[] = 2; n[]),
    ])
    @testset "Observables made before the program" begin
        check_cases(["a listener that stores a pair of two in a third" => ob_pair])
    end
end
