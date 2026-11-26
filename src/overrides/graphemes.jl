# Grapheme breaks (`graphemes`, `titlecase` of a string, `textwidth` of a string): Julia asks utf8proc, in libjulia, whether there is a
# break between two characters, with a state that carries what the rules of Unicode need of the ones before (regional indicators, emoji
# sequences, Indic conjuncts). Whether there is one depends on the *class* of each of the two characters (its `boundclass` and its Indic
# conjunct break: a few dozen kinds of them) and on the state, so it is a finite automaton: when this package is compiled the automaton is
# found from utf8proc's own function (with a representative of each class of characters, the states that it goes through, and what it answers
# in each), and the program has it as tables, and a table of the class of each character (as runs, like the properties in `strings.jl`).

# the class of a code point: the `boundclass` and `indic_conjunct_break` fields of utf8proc's property of it (the bits after the ten 16-bit
# fields and the five one-bit fields and the width of `utf8proc_property_t`; checked against utf8proc's answers by `test/core/strings.jl`)
function grapheme_class(cp::UInt32)
    p = ccall(:utf8proc_get_property, Ptr{UInt8}, (Int32,), Int32(cp))
    bits = unsafe_load(Ptr{UInt32}(p + 20))
    return UInt8((bits >> 8) & 0xff) | (UInt8((bits >> 16) & 0x3) << 6) # (the boundclass has fewer than 64 values)
end

utf8proc_break(c1::UInt32, c2::UInt32, state::Base.RefValue{Int32}) = ccall(:utf8proc_grapheme_break_stateful, Bool, (UInt32, UInt32, Ref{Int32}), c1, c2, state)

struct GraphemeAutomaton
    classes::RunTable{UInt8}      # the type (the class, numbered from 0) of each code point
    invalid::UInt8                # the type of a number that is not a code point
    ntypes::Int
    first_break::Vector{Bool}     # [t1 * ntypes + t2 + 1]: a break between a character of type t1 and one of type t2, from the state 0
    first_next::Vector{UInt8}     # the state after (0: the state 0)
    later_break::Vector{Bool}     # [(state - 1) * ntypes + t2 + 1], from a state that is not 0
    later_next::Vector{UInt8}
    plain_break::Vector{Bool}     # [t1 * ntypes + t2 + 1]: `isgraphemebreak(c1, c2)`, with no state
end

function build_grapheme_automaton()
    cps = vcat(UInt32(0):UInt32(0x10ffff), UInt32(0x110000)) # (the last is a number that is not a code point: utf8proc gives it the property of an unassigned one)
    class = Dict{UInt32,UInt8}(cp => grapheme_class(cp) for cp in cps)
    # the types, numbered; a representative of each
    kinds = sort!(unique(values(class)))
    index = Dict{UInt8,UInt8}(k => UInt8(i - 1) for (i, k) in enumerate(kinds))
    rep = Dict{UInt8,UInt32}()
    for cp in cps
        t = index[class[cp]]
        haskey(rep, t) || (rep[t] = cp)
    end
    nt = length(kinds)
    @assert nt < 255
    # the states, found as they are reached: the number that utf8proc gives, and ours
    numbers = Int32[0]
    number_of(v::Int32) = (i = findfirst(==(v), numbers); i === nothing ? (push!(numbers, v); length(numbers)) : i) - 1
    first_break = fill(false, nt * nt); first_next = zeros(UInt8, nt * nt); plain_break = fill(false, nt * nt)
    for t1 in 0:nt-1, t2 in 0:nt-1
        state = Ref{Int32}(0)
        first_break[t1 * nt + t2 + 1] = utf8proc_break(rep[UInt8(t1)], rep[UInt8(t2)], state)
        first_next[t1 * nt + t2 + 1] = UInt8(number_of(state[]))
        plain_break[t1 * nt + t2 + 1] = ccall(:utf8proc_grapheme_break, Bool, (UInt32, UInt32), rep[UInt8(t1)], rep[UInt8(t2)])
    end
    later_break = Bool[]; later_next = UInt8[]
    s = 1
    while s < length(numbers)
        # (the state is 1-based here: `numbers[s + 1]` is the state `s`; the character before does not matter once there is a state: tested with each type)
        v = numbers[s + 1]
        for t2 in 0:nt-1
            answers = Set{Tuple{Bool,Int32}}()
            for t1 in 0:nt-1
                state = Ref{Int32}(v)
                b = utf8proc_break(rep[UInt8(t1)], rep[UInt8(t2)], state)
                push!(answers, (b, state[]))
            end
            length(answers) == 1 || error("the grapheme break from the state $v depends on the character before it: $answers")
            (b, next) = only(answers)
            push!(later_break, b)
            push!(later_next, UInt8(number_of(next)))
        end
        s += 1
    end
    length(numbers) < 255 || error("too many states of the grapheme breaks")
    classes = RunTable(cp -> index[class[cp]], UInt8)
    # (each exactly as long as it is, and not as `fill`, `zeros` and `push!` leave them: the room is in the binary, with the table)
    return GraphemeAutomaton(classes, index[class[UInt32(0x110000)]], nt, copy(first_break), copy(first_next), copy(later_break), copy(later_next), copy(plain_break))
end

const GRAPHEMES = build_grapheme_automaton()

@inline function grapheme_type(a::GraphemeAutomaton, c::AbstractChar)
    cp = UInt32(c)
    return cp > 0x10ffff ? a.invalid : lookup(a.classes, cp)
end

# (plain functions, so that they can be tested against Base's: the overrides are these)
@inline function automaton_break!(a::GraphemeAutomaton, state::Ref{Int32}, c1::AbstractChar, c2::AbstractChar)
    if Base.ismalformed(c1) || Base.ismalformed(c2)
        state[] = 0
        return true
    end
    t2 = Int(grapheme_type(a, c2))
    s = state[]
    if s == 0
        i = Int(grapheme_type(a, c1)) * a.ntypes + t2 + 1
        @inbounds state[] = Int32(a.first_next[i])
        return @inbounds a.first_break[i]
    else
        i = (Int(s) - 1) * a.ntypes + t2 + 1
        @inbounds state[] = Int32(a.later_next[i])
        return @inbounds a.later_break[i]
    end
end

@inline function automaton_break(a::GraphemeAutomaton, c1::AbstractChar, c2::AbstractChar)
    (Base.ismalformed(c1) || Base.ismalformed(c2)) && return true
    return @inbounds a.plain_break[Int(grapheme_type(a, c1)) * a.ntypes + Int(grapheme_type(a, c2)) + 1]
end

@device_override @inline Base.Unicode.isgraphemebreak!(state::Ref{Int32}, c1::AbstractChar, c2::AbstractChar) = automaton_break!(GRAPHEMES, state, c1, c2)
@device_override @inline Base.Unicode.isgraphemebreak(c1::AbstractChar, c2::AbstractChar) = automaton_break(GRAPHEMES, c1, c2)
