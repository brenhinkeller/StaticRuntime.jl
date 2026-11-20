# The method table of this package, and the parameters of our compilations.
#
# StaticCompiler compiles with an overlay method table (`StaticCompiler.method_table`), whose overrides include
# replacements of Base's error helpers with functions that print and exit (from its `quirks.jl`): they prevent errors
# from being caught. A compilation uses exactly one overlay table (overlays do not stack), with Base as the fallback, so
# this package has a table of its own, holding only its overrides (`@device_override`), and compiles with it by default:
# Julia's own error helpers, which throw, are used. Pass `method_table = StaticCompiler.method_table` for
# StaticCompiler's.

# The parameters of the compilations of this package. GPUCompiler's functions that we specialize (`inference_params`,
# `optimize!`, ...) are for this type, which is ours, and so they don't change what StaticCompiler's own compilations
# do.
#
# GPUCompiler keeps what it infers apart for each value of the parameters (they are part of the token that owns the code
# instances, which is the same token if they are the same values), and what it asks of a job for inference
# (`inference_params`, ...) has to be made of them. So they are all that inference can depend on, and what they hold is
# all that it does depend on: `key`, a number made of the state of the compilation in the pass that is made (see
# `inference_key`: the settings, what is registered, and what the passes found), and the limit that is asked for by the
# job (`split_limit`). Two compilations at the same state have the same parameters, and what is inferred for one is used
# for the other.
struct OverridesParams <: GPUCompiler.AbstractCompilerParams
    key::Int
    split_limit::Int
    id::Int          # the cache of the compilation (`Compilation.id`): its own, so that what another compilation inferred is not found
end

OverridesParams(c) = OverridesParams(cache_key(c), c.settings.split_limit, c.id) # (the compilation `c`: see compilation.jl and passes.jl)

OverridesParams() = OverridesParams(Compilation())                 # (of a compilation that has just begun)

Base.Experimental.@MethodTable(method_table)

@doc """
    StaticRuntime.method_table

The overlay method table of this package, which `@device_override` adds methods to, and which the functions
that compile (`compile_executable` and the others) use by default.
""" method_table

"""
    @device_override old_bad_method(args...) = new_good_method(args...)

Override a method that can't be compiled statically (`old_bad_method`) with one that can, in the
method table of StaticRuntime, which is the one used by the functions of this package
(`compile_executable`, ...). Unlike `StaticCompiler.@device_override`, this does not affect
compilation with StaticCompiler's own functions.
"""
macro device_override(ex)
    return esc(:($Base.Experimental.@consistent_overlay($(GlobalRef(@__MODULE__, :method_table)), $ex)))
end
