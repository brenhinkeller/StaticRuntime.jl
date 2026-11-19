# CairoMakie in a program: a figure (made before the program is compiled, see the extension for Makie) drawn with Cairo, to an image that the program writes (`Cairo.write_to_png(screen.surface, path)`).

module StaticRuntimeCairoMakieExt

using StaticRuntime: StaticRuntime, @device_override
using CairoMakie: CairoMakie, Makie
using CairoMakie.Makie: Scene
const Cairo = CairoMakie.Cairo

# The screen is of the type of what it draws to (`Screen{IMAGE}`, `Screen{PDF}`), which the package reads from the surface when the screen is made (`get_render_type(surface)`, a value of the library): a type that is made when
# the program runs. A surface of an image is always one of `IMAGE`: the screen of one is made here with its type known (the same as the package's, otherwise).
@device_override function CairoMakie.Screen(scene::Scene, config::CairoMakie.ScreenConfig, surface::Cairo.CairoSurfaceImage)
    dsf = CairoMakie.device_scaling_factor(CairoMakie.IMAGE, config)
    CairoMakie.surface_set_device_scale(surface, dsf)
    ctx = Cairo.CairoContext(surface)
    aa = CairoMakie.to_cairo_antialias(config.antialias)
    Cairo.set_antialias(ctx, aa)
    CairoMakie.set_miter_limit(ctx, 2.0)
    return CairoMakie.Screen{CairoMakie.IMAGE}(scene, surface, ctx, dsf, aa, config.visible, config)
end

end # module
