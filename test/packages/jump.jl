# JuMP and MathOptInterface, solved with HiGHS (a library that the program opens, at the path that it has when compiling). What works: MOI's functions called on the optimizer
# (`HiGHS.Optimizer`) itself, and a JuMP model made with `direct_model`, whose backend is the optimizer. Not yet: `Model(HiGHS.Optimizer)`, whose backend is a `CachingOptimizer` of
# MOI's bridges, which work out the types of the bridges (`Dict{Any,Type}`) when the program runs.
using JuMP, HiGHS
const MOI = JuMP.MOI

jp_terms(cs, vs) = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(c, v) for (c, v) in zip(cs, vs)], 0.0)

# max x + y, x + 2y <= 4, 3x + y <= 6, x, y >= 0 (the answer is 2.8, at x = 1.6, y = 1.2)
function jp_moi_lp(rhs)
    o = HiGHS.Optimizer()
    MOI.set(o, MOI.Silent(), true)
    x = MOI.add_variable(o); y = MOI.add_variable(o)
    MOI.add_constraint(o, x, MOI.GreaterThan(0.0)); MOI.add_constraint(o, y, MOI.GreaterThan(0.0))
    MOI.add_constraint(o, jp_terms((1.0, 2.0), (x, y)), MOI.LessThan(rhs))
    MOI.add_constraint(o, jp_terms((3.0, 1.0), (x, y)), MOI.LessThan(6.0))
    MOI.set(o, MOI.ObjectiveSense(), MOI.MAX_SENSE)
    MOI.set(o, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(), jp_terms((1.0, 1.0), (x, y)))
    MOI.optimize!(o)
    println(MOI.get(o, MOI.TerminationStatus()), " ", round(MOI.get(o, MOI.ObjectiveValue()); digits = 4), " ",
            round(MOI.get(o, MOI.VariablePrimal(), x); digits = 4), " ", round(MOI.get(o, MOI.VariablePrimal(), y); digits = 4))
    return 0
end

function jp_direct_lp(rhs)
    m = direct_model(HiGHS.Optimizer()); set_silent(m)
    @variable(m, x >= 0); @variable(m, y >= 0)
    @constraint(m, x + 2y <= rhs); @constraint(m, 3x + y <= 6)
    @objective(m, Max, x + y)
    optimize!(m)
    println(termination_status(m), " ", round(objective_value(m); digits = 4), " ", round(value(x); digits = 4), " ", round(value(y); digits = 4))
    return 0
end

@testset "JuMP" begin
    check_cases([
        "MOI on HiGHS, LP"           => () -> jp_moi_lp(4.0 + opaque(0.0)),
        "direct_model, LP"           => () -> jp_direct_lp(4.0 + opaque(0.0)),
    ])
end
