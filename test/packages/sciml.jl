# SciML: differential equations (`SciMLBase` and `OrdinaryDiffEq`). A problem is made with `ODEProblem{iip, FullSpecialize}` (`iip` says whether the function changes its first argument, which `ODEProblem(f, u0, tspan, p)` finds out
# when it runs, as the type of the problem is then not known to the compiler: it is `Any` in Julia too), and solved with a method of `OrdinaryDiffEq`. A function that has a signature is kept by the package in a `FunctionWrapper`, which
# is called through a pointer to a function of the runtime (see `ext/StaticRuntimeFunctionWrappersExt.jl`).

using SciMLBase, OrdinaryDiffEqTsit5, OrdinaryDiffEqVerner, OrdinaryDiffEqLowOrderRK, OrdinaryDiffEqRosenbrock, OrdinaryDiffEqSDIRK, StaticArrays, UnicodePlots

sc_decay(u, p, t) = -p * u
sc_decay!(du, u, p, t) = (du[1] = -p * u[1]; du[2] = -2p * u[2]; nothing)
sc_lorenz(u, p, t) = SVector(p[1] * (u[2] - u[1]), u[1] * (p[2] - u[3]) - u[2], u[1] * u[2] - p[3] * u[3])
sc_lorenz!(du, u, p, t) = (du[1] = p[1] * (u[2] - u[1]); du[2] = u[1] * (p[2] - u[3]) - u[2]; du[3] = u[1] * u[2] - p[3] * u[3]; nothing)
sc_bounce(u, p, t) = SVector(u[2], -9.8)
sc_problem(u0 = 1.0, p = 2.0) = ODEProblem{false, SciMLBase.FullSpecialize}(sc_decay, u0, (0.0, 1.0), p)
sc_solve_decay(alg; kw...) = () -> (sol = solve(sc_problem(1.0, 2.0 + opaque(0.0) - 1), alg; kw...); println(round(sol.u[end]; digits = 4), " ", length(sol.t)); 0)

# The example of the README and of the manual's home page, as it is there: the Lorenz system, plotted with UnicodePlots
function sc_readme_example(args::Vector{String})
    ρ = length(args) > 0 ? parse(Float64, args[1]) : 28.0
    prob = ODEProblem{false, SciMLBase.FullSpecialize}(sc_lorenz, SVector(1.0, 0.0, 0.0), (0.0, 30.0), SVector(10.0, ρ, 8 / 3))
    sol = solve(prob, Tsit5(); saveat = 0.01)
    x = [u[1] for u in sol.u]
    z = [u[3] for u in sol.u]
    println(lineplot(x, z; title = "Lorenz attractor, ρ = $ρ", xlabel = "x", ylabel = "z", width = 60, height = 20))
    println(length(sol.t), " points, ", sol.stats.naccept, " steps")
    return 0
end

@testset "SciML" begin
    check_cases([
        "scalar ODE, Tsit5"        => () -> (sol = solve(sc_problem(1.0 + opaque(0.0) - 1), Tsit5(); reltol = 1e-8, abstol = 1e-8); println(round(sol.u[end]; digits = 5)); 0),
        "in-place vector ODE"      => () -> (sol = solve(ODEProblem{true, SciMLBase.FullSpecialize}(sc_decay!, [1.0, opaque(1.0) - 1], (0.0, 1.0), 2.0), Tsit5()); println(round(sol.u[end][1]; digits = 4)); 0),
        "the number of steps"      => () -> (sol = solve(sc_problem(1.0, 2.0 + opaque(0.0) - 1), Tsit5()); println(length(sol.t)); 0),
        "saveat"                   => () -> (sol = solve(sc_problem(1.0, 2.0 + opaque(0.0) - 1), Tsit5(); saveat = 0.25); println(length(sol.t), " ", round(sol.u[3]; digits = 4)); 0),
        "interpolation"            => () -> (sol = solve(sc_problem(1.0, 2.0 + opaque(0.0) - 1), Tsit5()); println(round(sol(0.5); digits = 4)); 0),
        "an SVector"               => () -> (sol = solve(ODEProblem{false, SciMLBase.FullSpecialize}(sc_lorenz, SVector(1.0, 0.0, opaque(0.0) - 1), (0.0, 1.0), SVector(10.0, 28.0, 8 / 3)), Tsit5()); println(round.(sol.u[end]; digits = 3)); 0),
        "in-place Lorenz"          => () -> (sol = solve(ODEProblem{true, SciMLBase.FullSpecialize}(sc_lorenz!, [1.0, 0.0, opaque(0.0) - 1], (0.0, 1.0), [10.0, 28.0, 8 / 3]), Tsit5()); println(round.(sol.u[end]; digits = 3)); 0),
        "tstops, save_everystep"   => () -> (sol = solve(sc_problem(1.0, 2.0 + opaque(0.0) - 1), Tsit5(); tstops = [0.3, 0.6], save_everystep = false); println(length(sol.t), " ", round(sol.u[end]; digits = 4)); 0),
        "Vern7"                    => sc_solve_decay(Vern7(); reltol = 1e-10, abstol = 1e-10),
        "BS3"                      => sc_solve_decay(BS3()),
        "DP5"                      => sc_solve_decay(DP5()),
        "Euler, fixed step"        => sc_solve_decay(Euler(); dt = 0.1, adaptive = false),
        "RK4, fixed step"          => sc_solve_decay(RK4(); dt = 0.1, adaptive = false),
        "Rodas5P (stiff)"          => sc_solve_decay(Rodas5P()),
        "ImplicitEuler (stiff)"    => sc_solve_decay(ImplicitEuler()),
        "DiscreteCallback"         => () -> (cb = DiscreteCallback((u, t, integ) -> t > 0.5, integ -> (integ.u = integ.u * 2); save_positions = (false, false)); sol = solve(sc_problem(1.0, 2.0 + opaque(0.0) - 1), Tsit5(); callback = cb); println(round(sol.u[end]; digits = 4)); 0),
        "ContinuousCallback"       => () -> (cb = ContinuousCallback((u, t, integ) -> u[1], integ -> (integ.u = SVector(integ.u[1], -0.9 * integ.u[2]))); sol = solve(ODEProblem{false, SciMLBase.FullSpecialize}(sc_bounce, SVector(1.0, 0.0 + opaque(0.0) - 1), (0.0, 3.0), nothing), Tsit5(); callback = cb); println(round(sol.u[end][1]; digits = 3), " ", length(sol.t)); 0),
        "the README example: Lorenz, plotted with UnicodePlots" => () -> sc_readme_example([opaque("28")]),
    ])
end
