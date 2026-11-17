```@meta
CurrentModule = StaticRuntime
```

# StaticRuntime

Glue between [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) and
[StaticTools.jl](https://github.com/brenhinkeller/StaticTools.jl), to let as much ordinary Julia
code as possible compile to a standalone executable or shared library that does not depend on
`libjulia`.

```julia
using StaticRuntime   # also loads (and re-exports) StaticCompiler and StaticTools

function main(argc::Int, argv::Ptr{Ptr{UInt8}})
    v = collect(1:argc+3)       # an ordinary Vector
    printf(c"%d\n", sum(v))
    return 0
end

compile_executable(main, (Int, Ptr{Ptr{UInt8}}))
```

Julia 1.14 or later is required.

## What works

Code that allocates (`Vector`, `Dict`, `Set`, `String`, closures that escape, boxed values),
`print`/`println`/`show` of numbers, strings, characters, symbols, arrays, tuples, pairs and types, `readline` and friends,
`rand`/`randn` on the default RNG, linear algebra (see [Linear algebra and BLAS](@ref)), and `try`/`catch`/`finally`/`rethrow` (including for errors thrown by Base, like `BoundsError`), in addition to what
StaticCompiler already handled (allocation-free numerical code, StaticTools types, and so on).
The tests in `test/corpus.jl` are the up-to-date list of the idioms that we check, and which of
them are known not to work yet. [Known limitations](@ref) gathers what does not work, or works differently.

See [Input and output](@ref) for printing and reading, and [Entry points](@ref) for how to get the
arguments of the command line.
