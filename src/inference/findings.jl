# What is found while a method is inferred and optimized (the function types its code has, the callbacks and
# `@cfunction`s it declares, its unknown calls, the boxes it makes, the questions it asked of the compilation's state).
# A method taken from the cache is not inferred again, so this is kept with its result (`analysis_results`, which the
# cache keeps) and replayed from every method that the program reaches (`replay_findings!`): what a compilation finds
# does not depend on what was inferred before it.

Base.@kwdef mutable struct InferenceFindings
    functions::Vector{Type} = Type[]
    callbacks::Vector{Tuple{Type,Type}} = Tuple{Type,Type}[]
    cfunctions::Vector{Tuple{DataType,Vector{DataType},DataType,Any}} = Tuple{DataType,Vector{DataType},DataType,Any}[]
    noted::Vector{Tuple{Symbol,Type}} = Tuple{Symbol,Type}[]  # `note_type(kind, T)`
    noted_asked::Vector{Symbol} = Symbol[]                    # `call_over_noted(kind, ...)`
    boxes::Vector{Tuple{Core.CodeInfo,Core.MethodInstance}} = Tuple{Core.CodeInfo,Core.MethodInstance}[] # code that makes boxes, as inferred (for `learn_boxes!`)
    dispatch_requested::Bool = false
    union_used::Bool = false
    callback_call_requested::Bool = false
    box_function_seen::Bool = false
    deps::Union{Nothing,Dict{Any,Any}} = nothing # questions asked of the compilation's state, with their answers (passes.jl)
end

findings_of(x) = CC.traverse_analysis_results(x) do @nospecialize result
    result isa InferenceFindings ? result : nothing
end

function findings!(result::CC.InferenceResult)
    f = findings_of(result)
    f === nothing || return f
    f = InferenceFindings()
    CC.stack_analysis_result!(result, f)
    return f
end

# (the frame of inference that a call is made in: not the one of a method that is looked at again with the constants of
# a call, which is not what is kept)
function frame_findings(sv)
    # (a frame that is made for the constants of a call is not what is kept: what it finds is kept with the frame that
    # made the call, whose code has it)
    while sv isa CC.InferenceState && sv.result.overridden_by_const !== nothing
        sv = CC.frame_parent(sv)
    end
    return sv isa CC.InferenceState ? findings!(sv.result) : nothing
end

function note_flag!(sv, name::Symbol)
    f = frame_findings(sv)
    f === nothing || setfield!(f, name, true)
    return
end

function replay_findings!(c::Compilation, interp, root)
    cl = c.closures
    for ci in reachable_code_instances(interp, root)
        f = findings_of(ci)
        f === nothing && continue
        for T in f.functions
            add_seen_function!(cl, T)
        end
        for x in f.callbacks
            x in cl.seen_callbacks || push!(cl.seen_callbacks, x)
        end
        for x in f.noted
            x in cl.seen_noted || push!(cl.seen_noted, x)
        end
        for k in f.noted_asked
            push!(cl.asked_noted, k)
        end
        for x in f.cfunctions
            any(s -> s[1] === x[1] && s[2] == x[2] && s[3] === x[3], cl.seen_cfunctions) || push!(cl.seen_cfunctions, x)
        end
        f.dispatch_requested && (cl.dispatch_requested = true)
        f.union_used && (cl.union_used = true)
        f.callback_call_requested && (cl.callback_call_requested = true)
        f.box_function_seen && (cl.box_function_seen = true)
        for (src, mi) in f.boxes
            learn_boxes!(c.boxes, src, mi)
        end
    end
    return
end
