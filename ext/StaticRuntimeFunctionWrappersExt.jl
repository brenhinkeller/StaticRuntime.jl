# FunctionWrappers.jl (a function with a signature that is fixed, as a value of one type: SciML keeps the functions that
# it calls in it, to compile less) in a program.
#
# A `FunctionWrapper` calls its function through a pointer to a `@cfunction` that is made when the wrapper is, and that
# has the function (a reference to it) as its first argument. A program has no runtime to make the pointer with, and the
# call is made through the one type that all the wrappers of a signature have, though the function is of a type of its
# own. The wrapper has the reference to the function as well (`obj`), and the call is made through that: its type is one
# of those that the wrappers of the program were made with (see "What the slots of the program hold" in the manual), and
# the call is split over them.

module StaticRuntimeFunctionWrappersExt

using StaticRuntime: @device_override
using FunctionWrappers: FunctionWrappers, FunctionWrapper

# (no pointer to a function of the runtime: it is not used)
@device_override FunctionWrappers.gen_fptr(::Type, ::Type, ::Type) = Ptr{Cvoid}(0)

# (the arguments are converted to the types of the signature, and the result to its type, as the wrapper does before and
# after its call)
@device_override @inline function (f::FunctionWrapper{Ret,Args})(args...) where {Ret,Args}
    obj = getfield(f, :obj)
    return FunctionWrappers.convert_ret(Ret, obj[](convert_arguments(Args, args)...))
end
@generated function convert_arguments(::Type{Args}, args::Tuple) where {Args<:Tuple}
    return Expr(:tuple, (:(convert($(fieldtype(Args, i)), args[$i])) for i in 1:fieldcount(Args))...)
end

end # module
