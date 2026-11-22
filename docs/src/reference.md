# API Reference

```@index
```

```@autodocs
Modules = [StaticRuntime, StaticRuntime.Runtime]
```

# Source layout

* `src/method_table.jl`: our method table, `@device_override` and the parameters of our compilations; `src/StaticRuntime.jl`: the module, `compile_executable` and the other entry points; `src/extensions.jl`: the functions that package extensions add methods to; `src/registry.jl`: what packages register (`REGISTRY`, which each compilation copies when it starts).
* `src/overrides/`: the overlay methods of Base and of the standard libraries, by topic (`io.jl`, `printing.jl`, `strings.jl`, `collections.jl`, `system.jl`, `bignum.jl`, ...).
* `src/inference/`: what the compiler does with what Julia's inference leaves to the runtime. The state of a compilation and its keys (`compilation.jl`), our interpreter (`interpreter.jl`), the passes and what each reuses from the one before (`passes.jl`); calls on abstract types (`dispatch.jl`), tuples (`tuples.jl`), unknown functions, callbacks and listeners (`closures.jl`), boxes (`boxes.jl`), slots of abstract types (`slots.jl`) and of types (`types_as_values.jl`), constant objects (`objects.jl`, `object_calls.jl`), stated types (`assume.jl`), `@cfunction` (`cfunctions.jl`), replaced calls (`redirect.jl`), the optimizer's hooks (`optimize.jl`), and why a program does not infer (`diagnostics.jl`).
* `src/runtime/`: the runtime that is linked into a program: the allocator and collector (`heap.jl`, `heap_link.jl`), the objects that are copied into the binary (`objects.jl`, `embedder.jl`, `constants.jl`), types at run time (`types.jl`), what is refused (`strict.jl`), and the functions of libraries, BLAS among them (`libraries.jl`, `loader.jl`).
* `src/llvm/`: our LLVM passes (`pipeline.jl`, `tags.jl`); `src/testing.jl`: `static_status` and the other functions that compare a compiled program with Julia.
* `ext/`: the overlays that need another package or standard library (LinearAlgebra, SparseArrays, Printf, Random, StyledStrings, Mmap, Observables, Makie, CairoMakie, UnicodePlots, MPI, FunctionWrappers).

