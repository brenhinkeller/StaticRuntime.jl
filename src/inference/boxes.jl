# The types of what the boxes of closures hold.
#
# A variable that a closure captures and that is assigned more than once is a `Core.Box`: what is read from it is `Any`,
# and calls on it dispatch. Here a read of a box (`getfield(box, :contents)`) is given the union of the types assigned
# to the variable, as the pass before found them; the box field of each closure that captures it gets the same type.
# Only for boxes that nothing but the method and its closures reads or assigns, and that no closure assigns. A variable
# assigned from itself (`y = y * 2`) keeps its type if what is assigned is of that type; otherwise the union grows, and
# a box whose union is not closed is left as it is. Also: fields of pointers that extensions make again where they are
# null (`remade_by`), and the hooks of `getfield` and `memoryrefget` that give reads of boxes and slots their types.

# (`slot = Core.Box(args...)`: the slot and the call, or `nothing`)
function box_creation(code, st)
    st isa Expr && st.head === :(=) && length(st.args) == 2 && st.args[1] isa Core.SlotNumber || return nothing
    call = st.args[2]
    call isa Expr && call.head === :call && called_function(code, call.args[1]) === Core.Box || return nothing
    return st.args[1].id, call
end

# the slot that a statement reads (`_7`), or `nothing`
slot_read(code, x) = x isa Core.SlotNumber ? x.id : (x isa Core.SSAValue && code[x.id] isa Core.SlotNumber ? code[x.id].id : nothing)

function operand_type(src::Core.CodeInfo, x)
    if x isa Core.SSAValue
        t = src.ssavaluetypes isa Vector ? src.ssavaluetypes[x.id] : Any
        return CC.widenconst(t)
    elseif x isa Core.SlotNumber
        return src.slottypes isa Vector ? CC.widenconst(src.slottypes[x.id]) : Any
    elseif x isa Core.Argument
        return src.slottypes isa Vector ? CC.widenconst(src.slottypes[x.n]) : Any
    elseif x isa QuoteNode
        return typeof(x.value)
    elseif x isa GlobalRef
        return Any
    elseif x isa Core.BindingPartition
        # (the code refers to a global through its binding partition: a constant has the type of its value)
        return is_const_partition(x) ? typeof(x.restriction) : Any
    elseif x isa Expr
        return Any
    else
        return typeof(x)
    end
end

# whether a closure of this type (or one that it makes) assigns a variable that it took: `setfield!(box, :contents,
# value)`
function closure_assigns_box(T, world::UInt, seen::Set{Any}, depth::Int = 0)
    T isa Type || return true
    T in seen && return false
    push!(seen, T)
    depth > 4 && return true
    ms = Base._methods_by_ftype(Tuple{Base.unwrap_unionall(T), Vararg{Any}}, nothing, -1, world)
    ms isa Vector || return true
    for mm in ms
        m = (mm::Core.MethodMatch).method
        isdefined(m, :source) || isdefined(m, :generator) && return true
        src = try Base.uncompressed_ast(m) catch; return true end
        code = src.code
        for st in code
            call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
            call isa Expr || continue
            if call.head === :call && length(call.args) >= 4 && called_function(code, call.args[1]) === Core.setfield! &&
               call.args[3] isa QuoteNode && call.args[3].value === :contents
                return true
            elseif call.head === :new && length(call.args) >= 2
                C = called_function(code, call.args[1])
                C isa Type && C !== Core.Box && closure_assigns_box(C, world, seen, depth + 1) && return true
            end
        end
    end
    return false
end

# The statements that are made from what is read from the box in `slot`, directly or through other statements and
# variables: their types are those of the code inferred with the box as it was, so they say nothing about what the box
# holds (a value made from an `Any` is a union of whatever the registered types make of it)
function box_dependents(code, slot::Int)
    ssa = Set{Int}()
    slots = Set{Int}()
    refs(x) = (x isa Core.SSAValue && x.id in ssa) || (x isa Core.SlotNumber && x.id in slots)
    changed = true
    while changed
        changed = false
        for (pc, st) in enumerate(code)
            call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
            call isa Expr || (call isa Core.SSAValue && refs(call) && !(pc in ssa) && (push!(ssa, pc); changed = true); continue)
            tainted = false
            if call.head === :call && length(call.args) >= 3 && call.args[3] isa QuoteNode && call.args[3].value === :contents &&
               called_function(code, call.args[1]) === Core.getfield && slot_read(code, call.args[2]) == slot
                tainted = true
            elseif any(refs, call.args)
                tainted = true
            end
            tainted || continue
            pc in ssa || (push!(ssa, pc); changed = true)
            if st isa Expr && st.head === :(=) && st.args[1] isa Core.SlotNumber && !(st.args[1].id in slots)
                push!(slots, st.args[1].id)
                changed = true
            end
        end
    end
    return ssa, slots
end

# the closures that were made with the box, as the type of the field that it is: `closures` are the type of each and the
# place of the box in the call that makes it
function record_closure_fields!(bx::BoxState, closures, code, T)
    for (C, i) in closures
        C isa DataType && 1 <= i <= fieldcount(C) && fieldtype(C, i) === Core.Box || continue
        bx.seen[(C, fieldname(C, i))] = T
    end
end

# The types of what each box of the code holds, as far as that can be known: `bx.seen`. (Run after the code has been
# inferred, before it is optimized: the statements are those of the lowered code, with their types.)
function learn_boxes!(bx::BoxState, src::Core.CodeInfo, mi::Core.MethodInstance)
    code = src.code
    created = Dict{Int,Int}()   # slot => number of the box
    ambiguous = Set{Int}()
    n = 0
    for st in code
        b = box_creation(code, st)
        b === nothing && continue
        n += 1
        haskey(created, b[1]) ? push!(ambiguous, b[1]) : (created[b[1]] = n)
    end
    isempty(created) && return
    types = Dict{Int,Vector{Any}}(s => Any[] for s in keys(created))
    free = Dict{Int,Vector{Any}}(s => Any[] for s in keys(created)) # (those that are not made from what is read from the box)
    unsafe = Set{Int}(ambiguous)
    closures = Dict{Int,Vector{Any}}(s => Any[] for s in keys(created))
    dependents = Dict{Int,Tuple{Set{Int},Set{Int}}}(s => box_dependents(code, s) for s in keys(created))
    independent(box, x) = !((x isa Core.SSAValue && x.id in dependents[box][1]) || (x isa Core.SlotNumber && x.id in dependents[box][2]))
    for (pc, st) in enumerate(code)
        b = box_creation(code, st)
        if b !== nothing
            for a in b[2].args[2:end]
                push!(types[b[1]], operand_type(src, a))
                independent(b[1], a) && push!(free[b[1]], operand_type(src, a))
            end
            continue
        end
        st isa Expr || continue
        # (a statement that only reads the slot, `%3 = _7`, is how it is used: the uses are those of that value)
        call = st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
        call isa Expr || continue
        if call.head === :call
            f = called_function(code, call.args[1])
            box = length(call.args) >= 2 ? slot_read(code, call.args[2]) : nothing
            if box !== nothing && haskey(created, box) && length(call.args) >= 3 && call.args[3] isa QuoteNode && call.args[3].value === :contents &&
               (f === Core.getfield || f === Core.isdefined || f === Core.setfield!)
                if f === Core.setfield! && length(call.args) >= 4
                    push!(types[box], operand_type(src, call.args[4]))
                    independent(box, call.args[4]) && push!(free[box], operand_type(src, call.args[4]))
                end
                continue
            end
        elseif call.head === :new
            C = called_function(code, call.args[1])
            for (i, a) in enumerate(call.args[2:end])
                box = slot_read(code, a)
                box !== nothing && haskey(created, box) && push!(closures[box], (C, i))
            end
            continue
        end
        # any other use of the box (an argument of a call, ...): not known what is done with it
        for a in call.args
            box = slot_read(code, a)
            box !== nothing && haskey(created, box) && !(code[pc] isa Core.SlotNumber) && push!(unsafe, box)
        end
    end
    world = Base.get_world_counter()
    for (slot, k) in created
        slot in unsafe && continue
        key = (mi.specTypes, k)
        key in bx.gave_up && continue
        any(c -> !(c[1] isa Type) || closure_assigns_box(c[1], world, Set{Any}()), closures[slot]) && (push!(bx.gave_up, key); continue)
        used = get(bx.types, key, nothing)
        stored = Any[t for t in types[slot] if t !== Union{}]
        if used === nothing
            T = Union{}
            for t in free[slot]
                (t === Union{} || t === Any) && continue
                T = Union{T, t}
            end
            (T === Union{} || Base.unionlen(T) > 8) && continue
            bx.seen[key] = T
            record_closure_fields!(bx, closures[slot], code, T)
        else
            bad = Any[t for t in stored if !(t <: used)]
            if isempty(bad)
                bx.seen[key] = used
                record_closure_fields!(bx, closures[slot], code, used)
            else
                T = Union{used, bad...}
                if T === Any || any(t -> t === Any, bad) || Base.unionlen(T) > 8
                    push!(bx.gave_up, key)
                    bx.seen[key] = Any # (said so that the next pass leaves the box as it is)
                    record_closure_fields!(bx, closures[slot], code, Any)
                else
                    bx.seen[key] = T
                    record_closure_fields!(bx, closures[slot], code, T)
                end
            end
        end
    end
    return
end

# the number of the box that a slot is, among those that the code makes (`slot = Core.Box()`): for the code of a method
function box_slots(bx::BoxState, src::Core.CodeInfo, mi::Core.MethodInstance)
    get!(bx.slot_numbers, (mi.specTypes, length(src.code))) do
        d = Dict{Int,Int}()
        n = 0
        for st in src.code
            b = box_creation(src.code, st)
            b === nothing && continue
            n += 1
            d[b[1]] = haskey(d, b[1]) ? -1 : n
        end
        d
    end
end

# The type of what is read from a box, `getfield(box, :contents)`, where it is known: `x` is the box as the statement
# has it (a slot of the method that made it, or a field of the closure that took it) (the key is asked about whether or
# not there are types of boxes yet: what is read depends on it, see `depends!`)
function box_content_type(c::Compilation, sv, @nospecialize(x))
    bx = c.boxes
    src = sv.src
    code = src.code
    mi = sv.linfo
    mi isa Core.MethodInstance || return nothing
    e = x isa Core.SSAValue && x.id <= length(code) ? code[x.id] : x
    if e isa Core.SlotNumber
        n = get(box_slots(bx, src, mi), e.id, 0)
        n > 0 || return nothing
        key = (mi.specTypes, n)
    elseif e isa Expr && e.head === :call && length(e.args) == 3 && e.args[3] isa QuoteNode && called_function(code, e.args[1]) === Core.getfield
        self = e.args[2]
        (self isa Core.SlotNumber && self.id == 1) || (self isa Core.Argument && self.n == 1) || return nothing
        key = (mi.specTypes.parameters[1], e.args[3].value)
    else
        return nothing
    end
    depends!(c, sv, (:box, key))
    T = get(bx.types, key, nothing)
    return T === Any ? nothing : T
end

# A read of a slot of types (see slots.jl) has the slots of the program looked at: it is what a program that has types
# as values does, which may make no other call that would have them looked at (`Vector{T}` of a `T` that is read is the
# builtin `apply_type`)
function type_slot_read!(c::Compilation, sv, key)
    (key === nothing || c.dispatch.registered_used || c.slots.mode === :off) && return
    type_value_declared(key[1] === :elem ? key[2] : fieldtype(key[2], key[3])) && note_dispatch_used!(c, sv)
    return
end

## Fields that are made again
#
# A pointer field of a constant object (a FreeType face in a font, a Cairo surface) holds an address of the compiling
# process, and is null in the program (the embedder writes it so). An extension says how to make it again with a method of
# `remade_by`: reads of the field become `remade_field`, which makes and stores it when it is null.

"""
    StaticRuntime.remade_by(::Type{T}, ::Val{name})

The function that makes the field `name` of an object of the type `T` again when the program reads it and it is null,
given the object (a field of a pointer of a constant, which is null in the program), or `nothing` (the default). An
extension of a package says it for its types with a method: `StaticRuntime.remade_by(::Type{FTFont}, ::Val{:ft_ptr}) =
program_face`. Only for fields of a `Ptr` type.
"""
remade_by(@nospecialize(T), @nospecialize(name)) = nothing

function remade_field(make, ::Val{name}, x) where {name}
    v = getfield(x, name)
    v == C_NULL || return v
    v = make(x)
    setfield!(x, name, v)
    return v
end

# (the function that a read of `getfield(x, name)` is made with, for its types, or `nothing`; not in `remade_field`
# itself, whose read is the field's)
function field_remaker(c::Compilation, @nospecialize(sv), argtypes::Vector{Any})
    length(argtypes) == 3 || return nothing
    name = argtypes[3]
    (name isa Core.Const && name.val isa Symbol) || return nothing
    T = CC.widenconst(argtypes[2])
    (T isa DataType && isconcretetype(T) && ismutabletype(T) && hasfield(T, name.val) && fieldtype(T, name.val) <: Ptr) || return nothing
    sv isa CC.InferenceState && (m = sv.linfo.def; m isa Method && m.name === :remade_field && m.module === @__MODULE__) && return nothing
    key = (T, name.val)
    haskey(c.objects.remakers, key) && return c.objects.remakers[key]
    make = try Base.invokelatest(remade_by, T, Val(name.val)) catch; nothing end
    c.objects.remakers[key] = make
    return make
end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.getfield), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    # (`getfield(Core, :stderr)`: the stream that a program has, see `standard_stream_of_call`)
    stream = standard_stream_of_call(arginfo)
    stream === nothing || return CC.Future(CC.CallMeta(Core.Const(stream), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
    # (a field of a struct by a name or an index that is not a constant: a comparison with each, see
    # `dynamic_field_plan`. The elements of a tuple that is a constant, and has types in it, are each a type that is
    # known, see `types_of_constant_tuple`, where the callee gives the `DataType` that they are all of)
    dynamic = dynamic_field_plan(arginfo.argtypes)
    dynamic === nothing || return redirect(interp, dynamic, Any[], 2, arginfo, si, vtypes, sv; to = 3)
    # (a field that is made again where it is null: see above)
    make = field_remaker(compilation(), sv, arginfo.argtypes)
    make === nothing || return redirect(interp, remade_field, Any[make, Val(arginfo.argtypes[3].val)], 2, arginfo, si, vtypes, sv; to = 2)
    call = julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
    # (an element of a tuple that is a constant, that has types in it, by an index that is not known: `Type[Int,
    # Float64][i]`: the types that it has, each a type that is known, and not the `DataType` that the field of the tuple
    # is)
    T = types_of_constant_tuple(arginfo.argtypes)
    if T !== nothing && (sv isa CC.InferenceState || CC.isready(call))
        return after_call(result_of_type, call, interp, sv, T)
    end
    c = compilation()
    # (an element of a tuple that is one of a few tuples: read as one of them, see `split_tuple_read` in tuples.jl)
    split = split_tuple_read(interp, arginfo, si, vtypes, sv)
    split === nothing || return split
    # (a field of an object that is known, which the program does not change: what it has, see objects.jl)
    arginfo.argtypes[2] isa Core.Const && depends!(c, sv, (:mode,)) # (see passes.jl)
    if c.slots.mode === :on && (sv isa CC.InferenceState || CC.isready(call))
        folded = fold_field_read(c, arginfo.argtypes, sv)
        if folded !== nothing
            return after_call(result_of_type, call, interp, sv, folded)
        end
        # (a field of an object that is known, which the program writes: what it has, and what is stored in it)
        OT = object_field_type(c, arginfo.argtypes, sv)
        if OT !== nothing
            return after_call(result_refined, call, interp, sv, OT)
        end
    end
    if isempty(c.slots.types) && !c.dispatch.registered_used && c.slots.mode !== :off && length(arginfo.argtypes) == 3 && arginfo.argtypes[3] isa Core.Const && (arginfo.argtypes[3].val isa Symbol || arginfo.argtypes[3].val isa Integer)
        type_slot_read!(c, sv, field_slot_key(arginfo.argtypes[2], arginfo.argtypes[3].val))
    end
    # (the box or the slot that is read is found whether or not any has types yet: what is read depends on it, see
    # `depends!`)
    argtypes = arginfo.argtypes
    length(argtypes) == 3 || return call
    t = argtypes[3]
    T = nothing
    if CC.widenconst(argtypes[2]) === Core.Box
        sv isa CC.InferenceState || return call
        (t isa Core.Const && t.val === :contents) || return call
        arginfo.fargs === nothing && return call
        T = box_content_type(c, sv, arginfo.fargs[2])
    elseif t isa Core.Const && (t.val isa Symbol || t.val isa Integer)
        # (a field of an abstract type: what has been stored in it, see slots.jl)
        key = field_slot_key(argtypes[2], t.val)
        key === nothing || (T = read_slot!(c, sv, key))
    end
    T === nothing && return call
    # (the interpretation of code that was inferred (`IRInterpretationState`) can not wait for what a call gives: a call
    # that is ready is the one that it can change)
    (sv isa CC.InferenceState || CC.isready(call)) || return call
    mentions_type_value(T) && in_type_slot_read(sv) && return call
    if mentions_type_value(T) && length(argtypes) == 3 && t isa Core.Const
        # (types as values: the read is the call of a check of them, see types_as_values.jl)
        return typed_read(CC.abstract_call(interp, CC.ArgInfo(nothing, Any[CC.Const(type_slot_field), argtypes[2], CC.Const(Val(t.val)), CC.Const(Val(T))]), si, vtypes, sv), T, interp, sv)
    end
    return after_call(result_refined, call, interp, sv, T)
end

# What is read from the elements of a memory of an abstract type (`Memory{Any}`) is of the types that were stored in
# them (see slots.jl)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.memoryrefget), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    call = julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
    c = compilation()
    length(arginfo.argtypes) >= 2 || return call
    key = elem_slot_key(arginfo.argtypes[2])
    T = key === nothing ? nothing : read_slot!(c, sv, key) # (asked whether or not there are types yet: see `depends!`)
    T === nothing || depends!(c, sv, (:types_empty,)) # (a type that is stated is used only once some slot has types: see passes.jl)
    if isempty(c.slots.types)
        type_slot_read!(c, sv, key)
        return call
    end
    (sv isa CC.InferenceState || CC.isready(call)) || return call
    T === nothing && return call
    mentions_type_value(T) && in_type_slot_read(sv) && return call # (the read of a check of types: it is the slot itself)
    if mentions_type_value(T) && length(arginfo.argtypes) == 4 && arginfo.argtypes[3] == CC.Const(:not_atomic) && arginfo.argtypes[4] == CC.Const(false)
        # (types as values: the read is the call of a check of them, see types_as_values.jl)
        return typed_read(CC.abstract_call(interp, CC.ArgInfo(nothing, Any[CC.Const(type_slot_get), arginfo.argtypes[2], CC.Const(Val(T))]), si, vtypes, sv), T, interp, sv)
    end
    return after_call(result_refined, call, interp, sv, T)
end
