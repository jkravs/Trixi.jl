# By default, Julia/LLVM does not use fused multiply-add operations (FMAs).
# Since these FMAs can increase the performance of many numerical algorithms,
# we need to opt-in explicitly.
# See https://ranocha.de/blog/Optimizing_EC_Trixi for further details.
@muladd begin
#! format: noindent

# everything related to a DG semidiscretization in 2D,
# currently limited to Lobatto-Legendre nodes

# This method is called when a SemidiscretizationHyperbolic is constructed.
# It constructs the basic `cache` used throughout the simulation to compute
# the RHS etc.
function create_cache(mesh::TreeMesh{2}, equations,
                      dg::DG, RealT, uEltype, backend::Backend)
    # Get cells for which an element needs to be created (i.e. all leaf cells)
    leaf_cell_ids = local_leaf_cells(mesh.tree)

    elements = init_elements(leaf_cell_ids, mesh, equations, dg.basis, RealT, uEltype, backend)

    interfaces = init_interfaces(leaf_cell_ids, mesh, elements, backend)

    boundaries = init_boundaries(leaf_cell_ids, mesh, elements, backend)

    mortars = init_mortars(leaf_cell_ids, mesh, elements, dg.mortar, backend)

    cache = (; elements, interfaces, boundaries, mortars)

    # Add specialized parts of the cache required to compute the volume integral etc.
    cache = (; cache...,
             create_cache(mesh, equations, dg.volume_integral, dg, uEltype)...)
    cache = (; cache..., create_cache(mesh, equations, dg.mortar, uEltype)...)

    return cache
end

# The methods below are specialized on the volume integral type
# and called from the basic `create_cache` method at the top.
function create_cache(mesh::Union{TreeMesh{2}, StructuredMesh{2}, UnstructuredMesh2D,
                                  P4estMesh{2}},
                      equations, volume_integral::VolumeIntegralFluxDifferencing,
                      dg::DG, uEltype)
    NamedTuple()
end

function create_cache(mesh::Union{TreeMesh{2}, StructuredMesh{2}, UnstructuredMesh2D,
                                  P4estMesh{2}}, equations,
                      volume_integral::VolumeIntegralShockCapturingHG, dg::DG, uEltype)
    element_ids_dg = Int[]
    element_ids_dgfv = Int[]

    cache = create_cache(mesh, equations,
                         VolumeIntegralFluxDifferencing(volume_integral.volume_flux_dg),
                         dg, uEltype)

    A3dp1_x = Array{uEltype, 3}
    A3dp1_y = Array{uEltype, 3}

    fstar1_L_threaded = A3dp1_x[A3dp1_x(undef, nvariables(equations), nnodes(dg) + 1,
                                        nnodes(dg)) for _ in 1:Threads.nthreads()]
    fstar1_R_threaded = A3dp1_x[A3dp1_x(undef, nvariables(equations), nnodes(dg) + 1,
                                        nnodes(dg)) for _ in 1:Threads.nthreads()]
    fstar2_L_threaded = A3dp1_y[A3dp1_y(undef, nvariables(equations), nnodes(dg),
                                        nnodes(dg) + 1) for _ in 1:Threads.nthreads()]
    fstar2_R_threaded = A3dp1_y[A3dp1_y(undef, nvariables(equations), nnodes(dg),
                                        nnodes(dg) + 1) for _ in 1:Threads.nthreads()]

    return (; cache..., element_ids_dg, element_ids_dgfv,
            fstar1_L_threaded, fstar1_R_threaded, fstar2_L_threaded, fstar2_R_threaded)
end

function create_cache(mesh::Union{TreeMesh{2}, StructuredMesh{2}, UnstructuredMesh2D,
                                  P4estMesh{2}}, equations,
                      volume_integral::VolumeIntegralPureLGLFiniteVolume, dg::DG,
                      uEltype)
    A3dp1_x = Array{uEltype, 3}
    A3dp1_y = Array{uEltype, 3}

    fstar1_L_threaded = A3dp1_x[A3dp1_x(undef, nvariables(equations), nnodes(dg) + 1,
                                        nnodes(dg)) for _ in 1:Threads.nthreads()]
    fstar1_R_threaded = A3dp1_x[A3dp1_x(undef, nvariables(equations), nnodes(dg) + 1,
                                        nnodes(dg)) for _ in 1:Threads.nthreads()]
    fstar2_L_threaded = A3dp1_y[A3dp1_y(undef, nvariables(equations), nnodes(dg),
                                        nnodes(dg) + 1) for _ in 1:Threads.nthreads()]
    fstar2_R_threaded = A3dp1_y[A3dp1_y(undef, nvariables(equations), nnodes(dg),
                                        nnodes(dg) + 1) for _ in 1:Threads.nthreads()]

    return (; fstar1_L_threaded, fstar1_R_threaded, fstar2_L_threaded,
            fstar2_R_threaded)
end

# The methods below are specialized on the mortar type
# and called from the basic `create_cache` method at the top.
function create_cache(mesh::Union{TreeMesh{2}, StructuredMesh{2}, UnstructuredMesh2D,
                                  P4estMesh{2}},
                      equations, mortar_l2::LobattoLegendreMortarL2, uEltype)
    # TODO: Taal performance using different types
    MA2d = MArray{Tuple{nvariables(equations), nnodes(mortar_l2)}, uEltype, 2,
                  nvariables(equations) * nnodes(mortar_l2)}
    fstar_upper_threaded = MA2d[MA2d(undef) for _ in 1:Threads.nthreads()]
    fstar_lower_threaded = MA2d[MA2d(undef) for _ in 1:Threads.nthreads()]

    # A2d = Array{uEltype, 2}
    # fstar_upper_threaded = [A2d(undef, nvariables(equations), nnodes(mortar_l2)) for _ in 1:Threads.nthreads()]
    # fstar_lower_threaded = [A2d(undef, nvariables(equations), nnodes(mortar_l2)) for _ in 1:Threads.nthreads()]

    (; fstar_upper_threaded, fstar_lower_threaded)
end

# TODO: Taal discuss/refactor timer, allowing users to pass a custom timer?

function rhs!(du, u, t,
              mesh::Union{TreeMesh{2}, P4estMesh{2}}, equations,
              initial_condition, boundary_conditions, source_terms::Source,
              dg::DG, cache) where {Source}
    # Reset du
    @trixi_timeit timer() "reset ∂u/∂t" reset_du!(du, dg, cache)

    # Calculate volume integral
    @trixi_timeit timer() "volume integral" begin
        calc_volume_integral!(du, u, mesh,
                              have_nonconservative_terms(equations), equations,
                              dg.volume_integral, dg, cache)
    end

    # Prolong solution to interfaces
    @trixi_timeit timer() "prolong2interfaces" begin
        prolong2interfaces!(cache, u, mesh, equations,
                            dg.surface_integral, dg)
    end

    # Calculate interface fluxes
    @trixi_timeit timer() "interface flux" begin
        calc_interface_flux!(cache.elements.surface_flux_values, mesh,
                             have_nonconservative_terms(equations), equations,
                             dg.surface_integral, dg, cache)
    end

    # Prolong solution to boundaries
    @trixi_timeit timer() "prolong2boundaries" begin
        prolong2boundaries!(cache, u, mesh, equations,
                            dg.surface_integral, dg)
    end

    # Calculate boundary fluxes
    @trixi_timeit timer() "boundary flux" begin
        calc_boundary_flux!(cache, t, boundary_conditions, mesh, equations,
                            dg.surface_integral, dg)
    end

    # Prolong solution to mortars
    @trixi_timeit timer() "prolong2mortars" begin
        prolong2mortars!(cache, u, mesh, equations,
                         dg.mortar, dg.surface_integral, dg)
    end

    # Calculate mortar fluxes
    @trixi_timeit timer() "mortar flux" begin
        calc_mortar_flux!(cache.elements.surface_flux_values, mesh,
                          have_nonconservative_terms(equations), equations,
                          dg.mortar, dg.surface_integral, dg, cache)
    end

    # Calculate surface integrals
    @trixi_timeit timer() "surface integral" begin
        calc_surface_integral!(du, u, mesh, equations,
                               dg.surface_integral, dg, cache)
    end

    # Apply Jacobian from mapping to reference element
    @trixi_timeit timer() "Jacobian" apply_jacobian!(du, mesh, equations, dg, cache)

    # Calculate source terms
    @trixi_timeit timer() "source terms" begin
        calc_sources!(du, u, t, source_terms, equations, dg, cache)
    end

    return nothing
end

function rhs_gpu!(du, u, t,
    mesh::Union{TreeMesh{2}, P4estMesh{2}}, equations,
    initial_condition, boundary_conditions, source_terms::Source,
    dg::DG, cache, backend::Backend) where {Source}

    # Select backend
    #backend = CUDABackend()
    #backend = CPU()

    # Offload u to device storage
    dev_u  = allocate(backend, eltype(u),  size(u))
    if !(backend isa CPU)
        copyto!(backend, dev_u, u)
    else
        Base.copyto!(dev_u, u)
    end

    # Reset du
    @trixi_timeit timer() "reset ∂u/∂t gpu" dev_du = fill!(allocate(backend, eltype(du), size(du)), 0)

    # Calculate volume integral
    @trixi_timeit timer() "volume integral gpu" calc_volume_integral_gpu!(
        dev_du, dev_u, mesh,
        have_nonconservative_terms(equations), equations,
        dg.volume_integral, dg, cache)

    # Prolong solution to interfaces
    @trixi_timeit timer() "prolong2interfaces gpu" prolong2interfaces_gpu!(
    cache, dev_u, mesh, equations, dg.surface_integral, dg)

    # Calculate interface fluxes
    @trixi_timeit timer() "interface flux gpu" calc_interface_flux_gpu!(
    cache.elements.surface_flux_values, mesh,
    have_nonconservative_terms(equations), equations,
    dg.surface_integral, dg, cache)

    # Prolong solution to boundaries
    @trixi_timeit timer() "prolong2boundaries gpu" prolong2boundaries_gpu!(
    cache, dev_u, mesh, equations, dg.surface_integral, dg)

    # Calculate boundary fluxes
    @trixi_timeit timer() "boundary flux gpu" calc_boundary_flux!(
    cache, t, boundary_conditions, mesh, equations, dg.surface_integral, dg)

    # Prolong solution to mortars
    @trixi_timeit timer() "prolong2mortars gpu" prolong2mortars_gpu!(
    cache, dev_u, mesh, equations, dg.mortar, dg.surface_integral, dg)

    # Calculate mortar fluxes
    @trixi_timeit timer() "mortar flux gpu" calc_mortar_flux_gpu!(
    cache.elements.surface_flux_values, mesh,
    have_nonconservative_terms(equations), equations,
    dg.mortar, dg.surface_integral, dg, cache)

    # Calculate surface integrals
    @trixi_timeit timer() "surface integral gpu" calc_surface_integral_gpu!(
    dev_du, dev_u, mesh, equations, dg.surface_integral, dg, cache)

    # Apply Jacobian from mapping to reference element
    @trixi_timeit timer() "Jacobian gpu" apply_jacobian_gpu!(
    dev_du, mesh, equations, dg, cache)

    # Calculate source terms
    @trixi_timeit timer() "source terms gpu" calc_sources_gpu!(
    dev_du, dev_u, t, source_terms, equations, dg, cache)

    if !(backend isa CPU)
        copyto!(backend, du, dev_du)
    else
        Base.copyto!(du, dev_du)
    end

    return nothing
end


function calc_volume_integral!(du, u,
                               mesh::Union{TreeMesh{2}, StructuredMesh{2},
                                           UnstructuredMesh2D, P4estMesh{2}},
                               nonconservative_terms, equations,
                               volume_integral::VolumeIntegralWeakForm,
                               dg::DGSEM, cache)
    @threaded for element in eachelement(dg, cache)
        weak_form_kernel!(du, u, element, mesh,
                          nonconservative_terms, equations,
                          dg, cache)
    end

    return nothing
end

function calc_volume_integral_gpu!(du, u,
                                   mesh::Union{TreeMesh{2}, StructuredMesh{2}, UnstructuredMesh2D, P4estMesh{2}},
                                   nonconservative_terms, equations,
                                   volume_integral::VolumeIntegralWeakForm,
                                   dg::DGSEM, cache)

    backend = get_backend(u)

    kernel! = weak_form_kernel_gpu!(backend)
    # Determine gridsize by number of node for each element
    num_nodes = nnodes(dg)
    num_elements = nelements(cache.elements)
    @unpack derivative_dhat = dg.basis

    kernel!(du, u, equations, derivative_dhat, num_nodes, ndrange=num_elements)
    # Ensure that device is finished
    synchronize(backend)

    return nothing
end

end #@muladd

@kernel function weak_form_kernel_gpu!(du, u,
                                       equations, derivative_dhat, num_nodes)

    element = @index(Global)

    for j in 1:num_nodes, i in 1:num_nodes
        #u_node = get_node_vars(u, equations, dg, i, j, element)
        u_node = SVector(ntuple(@inline(v -> u[v, i, j, element]), Val(nvariables(equations))))

        flux1 = flux(u_node, 1, equations)
        for ii in 1:num_nodes
            #multiply_add_to_node_vars!(du, alpha * derivative_dhat[ii, i], flux1, equations, dg, ii, j, element)
            #factor = alpha * derivative_dhat[ii, i]
            factor = derivative_dhat[ii, i]
            for v in eachvariable(equations)
                du[v, ii, j, element] = du[v, ii, j, element] + factor * flux1[v]
            end
        end

        flux2 = flux(u_node, 2, equations)
        for jj in 1:num_nodes
            #multiply_add_to_node_vars!(du, alpha * derivative_dhat[jj, j], flux2, equations, dg, i, jj, element)
            #factor = alpha * derivative_dhat[jj, j]
            factor = derivative_dhat[jj, j]
            for v in eachvariable(equations)
                du[v, i, jj, element] = du[v, i, jj, element] + factor * flux2[v]
            end
        end
    end
end

@muladd begin

@inline function weak_form_kernel!(du, u,
                                   element, mesh::TreeMesh{2},
                                   nonconservative_terms::False, equations,
                                   dg::DGSEM, cache, alpha = true)
    # true * [some floating point value] == [exactly the same floating point value]
    # This can (hopefully) be optimized away due to constant propagation.
    @unpack derivative_dhat = dg.basis

    # Calculate volume terms in one element
    for j in eachnode(dg), i in eachnode(dg)
        u_node = get_node_vars(u, equations, dg, i, j, element)

        flux1 = flux(u_node, 1, equations)
        for ii in eachnode(dg)
            multiply_add_to_node_vars!(du, alpha * derivative_dhat[ii, i], flux1,
                                       equations, dg, ii, j, element)
        end

        flux2 = flux(u_node, 2, equations)
        for jj in eachnode(dg)
            multiply_add_to_node_vars!(du, alpha * derivative_dhat[jj, j], flux2,
                                       equations, dg, i, jj, element)
        end
    end

    return nothing
end

# flux differencing volume integral. For curved meshes averaging of the
# mapping terms, stored in `cache.elements.contravariant_vectors`, is peeled apart
# from the evaluation of the physical fluxes in each Cartesian direction
function calc_volume_integral!(du, u,
                               mesh::Union{TreeMesh{2}, StructuredMesh{2},
                                           UnstructuredMesh2D, P4estMesh{2}},
                               nonconservative_terms, equations,
                               volume_integral::VolumeIntegralFluxDifferencing,
                               dg::DGSEM, cache)
    @threaded for element in eachelement(dg, cache)
        flux_differencing_kernel!(du, u, element, mesh,
                                  nonconservative_terms, equations,
                                  volume_integral.volume_flux, dg, cache)
    end
end

@inline function flux_differencing_kernel!(du, u,
                                           element, mesh::TreeMesh{2},
                                           nonconservative_terms::False, equations,
                                           volume_flux, dg::DGSEM, cache, alpha = true)
    # true * [some floating point value] == [exactly the same floating point value]
    # This can (hopefully) be optimized away due to constant propagation.
    @unpack derivative_split = dg.basis

    # Calculate volume integral in one element
    for j in eachnode(dg), i in eachnode(dg)
        u_node = get_node_vars(u, equations, dg, i, j, element)

        # All diagonal entries of `derivative_split` are zero. Thus, we can skip
        # the computation of the diagonal terms. In addition, we use the symmetry
        # of the `volume_flux` to save half of the possible two-point flux
        # computations.

        # x direction
        for ii in (i + 1):nnodes(dg)
            u_node_ii = get_node_vars(u, equations, dg, ii, j, element)
            flux1 = volume_flux(u_node, u_node_ii, 1, equations)
            multiply_add_to_node_vars!(du, alpha * derivative_split[i, ii], flux1,
                                       equations, dg, i, j, element)
            multiply_add_to_node_vars!(du, alpha * derivative_split[ii, i], flux1,
                                       equations, dg, ii, j, element)
        end

        # y direction
        for jj in (j + 1):nnodes(dg)
            u_node_jj = get_node_vars(u, equations, dg, i, jj, element)
            flux2 = volume_flux(u_node, u_node_jj, 2, equations)
            multiply_add_to_node_vars!(du, alpha * derivative_split[j, jj], flux2,
                                       equations, dg, i, j, element)
            multiply_add_to_node_vars!(du, alpha * derivative_split[jj, j], flux2,
                                       equations, dg, i, jj, element)
        end
    end
end

@inline function flux_differencing_kernel!(du, u,
                                           element, mesh::TreeMesh{2},
                                           nonconservative_terms::True, equations,
                                           volume_flux, dg::DGSEM, cache, alpha = true)
    # true * [some floating point value] == [exactly the same floating point value]
    # This can (hopefully) be optimized away due to constant propagation.
    @unpack derivative_split = dg.basis
    symmetric_flux, nonconservative_flux = volume_flux

    # Apply the symmetric flux as usual
    flux_differencing_kernel!(du, u, element, mesh, False(), equations, symmetric_flux,
                              dg, cache, alpha)

    # Calculate the remaining volume terms using the nonsymmetric generalized flux
    for j in eachnode(dg), i in eachnode(dg)
        u_node = get_node_vars(u, equations, dg, i, j, element)

        # The diagonal terms are zero since the diagonal of `derivative_split`
        # is zero. We ignore this for now.

        # x direction
        integral_contribution = zero(u_node)
        for ii in eachnode(dg)
            u_node_ii = get_node_vars(u, equations, dg, ii, j, element)
            noncons_flux1 = nonconservative_flux(u_node, u_node_ii, 1, equations)
            integral_contribution = integral_contribution +
                                    derivative_split[i, ii] * noncons_flux1
        end

        # y direction
        for jj in eachnode(dg)
            u_node_jj = get_node_vars(u, equations, dg, i, jj, element)
            noncons_flux2 = nonconservative_flux(u_node, u_node_jj, 2, equations)
            integral_contribution = integral_contribution +
                                    derivative_split[j, jj] * noncons_flux2
        end

        # The factor 0.5 cancels the factor 2 in the flux differencing form
        multiply_add_to_node_vars!(du, alpha * 0.5, integral_contribution, equations,
                                   dg, i, j, element)
    end
end

# TODO: Taal dimension agnostic
function calc_volume_integral!(du, u,
                               mesh::Union{TreeMesh{2}, StructuredMesh{2},
                                           UnstructuredMesh2D, P4estMesh{2}},
                               nonconservative_terms, equations,
                               volume_integral::VolumeIntegralShockCapturingHG,
                               dg::DGSEM, cache)
    @unpack element_ids_dg, element_ids_dgfv = cache
    @unpack volume_flux_dg, volume_flux_fv, indicator = volume_integral

    # Calculate blending factors α: u = u_DG * (1 - α) + u_FV * α
    alpha = @trixi_timeit timer() "blending factors" indicator(u, mesh, equations, dg,
                                                               cache)

    # Determine element ids for DG-only and blended DG-FV volume integral
    pure_and_blended_element_ids!(element_ids_dg, element_ids_dgfv, alpha, dg, cache)

    # Loop over pure DG elements
    @trixi_timeit timer() "pure DG" @threaded for idx_element in eachindex(element_ids_dg)
        element = element_ids_dg[idx_element]
        flux_differencing_kernel!(du, u, element, mesh,
                                  nonconservative_terms, equations,
                                  volume_flux_dg, dg, cache)
    end

    # Loop over blended DG-FV elements
    @trixi_timeit timer() "blended DG-FV" @threaded for idx_element in eachindex(element_ids_dgfv)
        element = element_ids_dgfv[idx_element]
        alpha_element = alpha[element]

        # Calculate DG volume integral contribution
        flux_differencing_kernel!(du, u, element, mesh,
                                  nonconservative_terms, equations,
                                  volume_flux_dg, dg, cache, 1 - alpha_element)

        # Calculate FV volume integral contribution
        fv_kernel!(du, u, mesh, nonconservative_terms, equations, volume_flux_fv,
                   dg, cache, element, alpha_element)
    end

    return nothing
end

# TODO: Taal dimension agnostic
function calc_volume_integral!(du, u,
                               mesh::TreeMesh{2},
                               nonconservative_terms, equations,
                               volume_integral::VolumeIntegralPureLGLFiniteVolume,
                               dg::DGSEM, cache)
    @unpack volume_flux_fv = volume_integral

    # Calculate LGL FV volume integral
    @threaded for element in eachelement(dg, cache)
        fv_kernel!(du, u, mesh, nonconservative_terms, equations, volume_flux_fv,
                   dg, cache, element, true)
    end

    return nothing
end

@inline function fv_kernel!(du, u,
                            mesh::Union{TreeMesh{2}, StructuredMesh{2},
                                        UnstructuredMesh2D, P4estMesh{2}},
                            nonconservative_terms, equations,
                            volume_flux_fv, dg::DGSEM, cache, element, alpha = true)
    @unpack fstar1_L_threaded, fstar1_R_threaded, fstar2_L_threaded, fstar2_R_threaded = cache
    @unpack inverse_weights = dg.basis

    # Calculate FV two-point fluxes
    fstar1_L = fstar1_L_threaded[Threads.threadid()]
    fstar2_L = fstar2_L_threaded[Threads.threadid()]
    fstar1_R = fstar1_R_threaded[Threads.threadid()]
    fstar2_R = fstar2_R_threaded[Threads.threadid()]
    calcflux_fv!(fstar1_L, fstar1_R, fstar2_L, fstar2_R, u, mesh,
                 nonconservative_terms, equations, volume_flux_fv, dg, element, cache)

    # Calculate FV volume integral contribution
    for j in eachnode(dg), i in eachnode(dg)
        for v in eachvariable(equations)
            du[v, i, j, element] += (alpha *
                                     (inverse_weights[i] *
                                      (fstar1_L[v, i + 1, j] - fstar1_R[v, i, j]) +
                                      inverse_weights[j] *
                                      (fstar2_L[v, i, j + 1] - fstar2_R[v, i, j])))
        end
    end

    return nothing
end

#     calcflux_fv!(fstar1_L, fstar1_R, fstar2_L, fstar2_R, u_leftright,
#                  nonconservative_terms::False, equations,
#                  volume_flux_fv, dg, element)
#
# Calculate the finite volume fluxes inside the elements (**without non-conservative terms**).
#
# # Arguments
# - `fstar1_L::AbstractArray{<:Real, 3}`
# - `fstar1_R::AbstractArray{<:Real, 3}`
# - `fstar2_L::AbstractArray{<:Real, 3}`
# - `fstar2_R::AbstractArray{<:Real, 3}`
@inline function calcflux_fv!(fstar1_L, fstar1_R, fstar2_L, fstar2_R,
                              u::AbstractArray{<:Any, 4},
                              mesh::TreeMesh{2}, nonconservative_terms::False,
                              equations,
                              volume_flux_fv, dg::DGSEM, element, cache)
    fstar1_L[:, 1, :] .= zero(eltype(fstar1_L))
    fstar1_L[:, nnodes(dg) + 1, :] .= zero(eltype(fstar1_L))
    fstar1_R[:, 1, :] .= zero(eltype(fstar1_R))
    fstar1_R[:, nnodes(dg) + 1, :] .= zero(eltype(fstar1_R))

    for j in eachnode(dg), i in 2:nnodes(dg)
        u_ll = get_node_vars(u, equations, dg, i - 1, j, element)
        u_rr = get_node_vars(u, equations, dg, i, j, element)
        flux = volume_flux_fv(u_ll, u_rr, 1, equations) # orientation 1: x direction
        set_node_vars!(fstar1_L, flux, equations, dg, i, j)
        set_node_vars!(fstar1_R, flux, equations, dg, i, j)
    end

    fstar2_L[:, :, 1] .= zero(eltype(fstar2_L))
    fstar2_L[:, :, nnodes(dg) + 1] .= zero(eltype(fstar2_L))
    fstar2_R[:, :, 1] .= zero(eltype(fstar2_R))
    fstar2_R[:, :, nnodes(dg) + 1] .= zero(eltype(fstar2_R))

    for j in 2:nnodes(dg), i in eachnode(dg)
        u_ll = get_node_vars(u, equations, dg, i, j - 1, element)
        u_rr = get_node_vars(u, equations, dg, i, j, element)
        flux = volume_flux_fv(u_ll, u_rr, 2, equations) # orientation 2: y direction
        set_node_vars!(fstar2_L, flux, equations, dg, i, j)
        set_node_vars!(fstar2_R, flux, equations, dg, i, j)
    end

    return nothing
end

#     calcflux_fv!(fstar1_L, fstar1_R, fstar2_L, fstar2_R, u_leftright,
#                  nonconservative_terms::True, equations,
#                  volume_flux_fv, dg, element)
#
# Calculate the finite volume fluxes inside the elements (**with non-conservative terms**).
#
# # Arguments
# - `fstar1_L::AbstractArray{<:Real, 3}`:
# - `fstar1_R::AbstractArray{<:Real, 3}`:
# - `fstar2_L::AbstractArray{<:Real, 3}`:
# - `fstar2_R::AbstractArray{<:Real, 3}`:
# - `u_leftright::AbstractArray{<:Real, 4}`
@inline function calcflux_fv!(fstar1_L, fstar1_R, fstar2_L, fstar2_R,
                              u::AbstractArray{<:Any, 4},
                              mesh::TreeMesh{2}, nonconservative_terms::True, equations,
                              volume_flux_fv, dg::DGSEM, element, cache)
    volume_flux, nonconservative_flux = volume_flux_fv

    # Fluxes in x
    fstar1_L[:, 1, :] .= zero(eltype(fstar1_L))
    fstar1_L[:, nnodes(dg) + 1, :] .= zero(eltype(fstar1_L))
    fstar1_R[:, 1, :] .= zero(eltype(fstar1_R))
    fstar1_R[:, nnodes(dg) + 1, :] .= zero(eltype(fstar1_R))

    for j in eachnode(dg), i in 2:nnodes(dg)
        u_ll = get_node_vars(u, equations, dg, i - 1, j, element)
        u_rr = get_node_vars(u, equations, dg, i, j, element)

        # Compute conservative part
        f1 = volume_flux(u_ll, u_rr, 1, equations) # orientation 1: x direction

        # Compute nonconservative part
        # Note the factor 0.5 necessary for the nonconservative fluxes based on
        # the interpretation of global SBP operators coupled discontinuously via
        # central fluxes/SATs
        f1_L = f1 + 0.5 * nonconservative_flux(u_ll, u_rr, 1, equations)
        f1_R = f1 + 0.5 * nonconservative_flux(u_rr, u_ll, 1, equations)

        # Copy to temporary storage
        set_node_vars!(fstar1_L, f1_L, equations, dg, i, j)
        set_node_vars!(fstar1_R, f1_R, equations, dg, i, j)
    end

    # Fluxes in y
    fstar2_L[:, :, 1] .= zero(eltype(fstar2_L))
    fstar2_L[:, :, nnodes(dg) + 1] .= zero(eltype(fstar2_L))
    fstar2_R[:, :, 1] .= zero(eltype(fstar2_R))
    fstar2_R[:, :, nnodes(dg) + 1] .= zero(eltype(fstar2_R))

    # Compute inner fluxes
    for j in 2:nnodes(dg), i in eachnode(dg)
        u_ll = get_node_vars(u, equations, dg, i, j - 1, element)
        u_rr = get_node_vars(u, equations, dg, i, j, element)

        # Compute conservative part
        f2 = volume_flux(u_ll, u_rr, 2, equations) # orientation 2: y direction

        # Compute nonconservative part
        # Note the factor 0.5 necessary for the nonconservative fluxes based on
        # the interpretation of global SBP operators coupled discontinuously via
        # central fluxes/SATs
        f2_L = f2 + 0.5 * nonconservative_flux(u_ll, u_rr, 2, equations)
        f2_R = f2 + 0.5 * nonconservative_flux(u_rr, u_ll, 2, equations)

        # Copy to temporary storage
        set_node_vars!(fstar2_L, f2_L, equations, dg, i, j)
        set_node_vars!(fstar2_R, f2_R, equations, dg, i, j)
    end

    return nothing
end

function prolong2interfaces!(cache, u,
                             mesh::TreeMesh{2}, equations, surface_integral, dg::DG)
    @unpack interfaces = cache
    @unpack orientations = interfaces

    @threaded for interface in eachinterface(dg, cache)
        left_element = interfaces.neighbor_ids[1, interface]
        right_element = interfaces.neighbor_ids[2, interface]

        if orientations[interface] == 1
            # interface in x-direction
            for j in eachnode(dg), v in eachvariable(equations)
                interfaces.u[1, v, j, interface] = u[v, nnodes(dg), j, left_element]
                interfaces.u[2, v, j, interface] = u[v, 1, j, right_element]
            end
        else # if orientations[interface] == 2
            # interface in y-direction
            for i in eachnode(dg), v in eachvariable(equations)
                interfaces.u[1, v, i, interface] = u[v, i, nnodes(dg), left_element]
                interfaces.u[2, v, i, interface] = u[v, i, 1, right_element]
            end
        end
    end
    return nothing
end

function prolong2interfaces_gpu!(cache, u,
                             mesh::TreeMesh{2}, equations, surface_integral, dg::DG)

    @kernel function internal_prolong2interfaces_gpu!(u, interfaces_u, interfaces_neighbor_ids, orientations, equations, num_nodes)
        interface = @index(Global)

        left_element  = interfaces_neighbor_ids[1, interface]
        right_element = interfaces_neighbor_ids[2, interface]

        if orientations[interface] == 1
            # interface in x-direction
            for j in 1:num_nodes, v in eachvariable(equations)
                interfaces_u[1, v, j, interface] = u[v, num_nodes, j, left_element]
                interfaces_u[2, v, j, interface] = u[v,         1, j, right_element]
            end
        else # if orientations[interface] == 2
            # interface in y-direction
            for i in 1:num_nodes, v in eachvariable(equations)
                interfaces_u[1, v, i, interface] = u[v, i, num_nodes, left_element]
                interfaces_u[2, v, i, interface] = u[v, i,         1, right_element]
            end
        end
    end

    @unpack interfaces = cache
    @unpack orientations = interfaces

    backend = get_backend(u)

    kernel! = internal_prolong2interfaces_gpu!(backend)
    num_nodes = nnodes(dg)
    num_interfaces = ninterfaces(interfaces)
    
    kernel!(u, interfaces.u, interfaces.neighbor_ids, orientations, equations, num_nodes, ndrange=num_interfaces)
    # Ensure that device is finished
    synchronize(backend)

    return nothing
end

function calc_interface_flux!(surface_flux_values,
                              mesh::TreeMesh{2},
                              nonconservative_terms::False, equations,
                              surface_integral, dg::DG, cache)
    @unpack surface_flux = surface_integral
    @unpack u, neighbor_ids, orientations = cache.interfaces

    @threaded for interface in eachinterface(dg, cache)
        # Get neighboring elements
        left_id = neighbor_ids[1, interface]
        right_id = neighbor_ids[2, interface]

        # Determine interface direction with respect to elements:
        # orientation = 1: left -> 2, right -> 1
        # orientation = 2: left -> 4, right -> 3
        left_direction = 2 * orientations[interface]
        right_direction = 2 * orientations[interface] - 1

        for i in eachnode(dg)
            # Call pointwise Riemann solver
            u_ll, u_rr = get_surface_node_vars(u, equations, dg, i, interface)
            flux = surface_flux(u_ll, u_rr, orientations[interface], equations)

            # Copy flux to left and right element storage
            for v in eachvariable(equations)
                surface_flux_values[v, i, left_direction, left_id] = flux[v]
                surface_flux_values[v, i, right_direction, right_id] = flux[v]
            end
        end
    end

    return nothing
end

end #@muladd

function calc_interface_flux_gpu!(surface_flux_values,
                              mesh::TreeMesh{2},
                              nonconservative_terms::False, equations,
                              surface_integral, dg::DG, cache)

    @kernel function internal_calc_interface_flux!(surface_flux_values, surface_flux, u, neighbor_ids, orientations, equations, num_nodes)

        interface = @index(Global)

        # Get neighboring elements
        left_id  = neighbor_ids[1, interface]
        right_id = neighbor_ids[2, interface]

        # Determine interface direction with respect to elements:
        # orientation = 1: left -> 2, right -> 1
        # orientation = 2: left -> 4, right -> 3
        left_direction  = 2 * orientations[interface]
        right_direction = 2 * orientations[interface] - 1

        for i in 1:num_nodes
            # Call pointwise Riemann solver
            u_ll = SVector(ntuple(@inline(v -> u[1, v, i, interface]), Val(nvariables(equations))))
            u_rr = SVector(ntuple(@inline(v -> u[2, v, i, interface]), Val(nvariables(equations))))
            flux = surface_flux(u_ll, u_rr, orientations[interface], equations)

            # Copy flux to left and right element storage
            for v in eachvariable(equations)
                surface_flux_values[v, i, left_direction,  left_id]  = flux[v]
                surface_flux_values[v, i, right_direction, right_id] = flux[v]
            end
        end
    end

    @unpack surface_flux  = surface_integral
    @unpack u, neighbor_ids, orientations = cache.interfaces

    backend = get_backend(u)

    kernel! = internal_calc_interface_flux!(backend)
    num_nodes = nnodes(dg)
    num_interfaces = ninterfaces(cache.interfaces)

    kernel!(surface_flux_values, surface_flux, u, neighbor_ids, orientations, equations, num_nodes, ndrange=num_interfaces)
    # Ensure that device is finished
    synchronize(backend)

    return nothing
end

@muladd begin

function calc_interface_flux!(surface_flux_values,
                              mesh::TreeMesh{2},
                              nonconservative_terms::True, equations,
                              surface_integral, dg::DG, cache)
    surface_flux, nonconservative_flux = surface_integral.surface_flux
    @unpack u, neighbor_ids, orientations = cache.interfaces

    @threaded for interface in eachinterface(dg, cache)
        # Get neighboring elements
        left_id = neighbor_ids[1, interface]
        right_id = neighbor_ids[2, interface]

        # Determine interface direction with respect to elements:
        # orientation = 1: left -> 2, right -> 1
        # orientation = 2: left -> 4, right -> 3
        left_direction = 2 * orientations[interface]
        right_direction = 2 * orientations[interface] - 1

        for i in eachnode(dg)
            # Call pointwise Riemann solver
            orientation = orientations[interface]
            u_ll, u_rr = get_surface_node_vars(u, equations, dg, i, interface)
            flux = surface_flux(u_ll, u_rr, orientation, equations)

            # Compute both nonconservative fluxes
            noncons_left = nonconservative_flux(u_ll, u_rr, orientation, equations)
            noncons_right = nonconservative_flux(u_rr, u_ll, orientation, equations)

            # Copy flux to left and right element storage
            for v in eachvariable(equations)
                # Note the factor 0.5 necessary for the nonconservative fluxes based on
                # the interpretation of global SBP operators coupled discontinuously via
                # central fluxes/SATs
                surface_flux_values[v, i, left_direction, left_id] = flux[v] +
                                                                     0.5 *
                                                                     noncons_left[v]
                surface_flux_values[v, i, right_direction, right_id] = flux[v] +
                                                                       0.5 *
                                                                       noncons_right[v]
            end
        end
    end

    return nothing
end

function prolong2boundaries!(cache, u,
                             mesh::TreeMesh{2}, equations, surface_integral, dg::DG)
    @unpack boundaries = cache
    @unpack orientations, neighbor_sides = boundaries

    @threaded for boundary in eachboundary(dg, cache)
        element = boundaries.neighbor_ids[boundary]

        if orientations[boundary] == 1
            # boundary in x-direction
            if neighbor_sides[boundary] == 1
                # element in -x direction of boundary
                for l in eachnode(dg), v in eachvariable(equations)
                    boundaries.u[1, v, l, boundary] = u[v, nnodes(dg), l, element]
                end
            else # Element in +x direction of boundary
                for l in eachnode(dg), v in eachvariable(equations)
                    boundaries.u[2, v, l, boundary] = u[v, 1, l, element]
                end
            end
        else # if orientations[boundary] == 2
            # boundary in y-direction
            if neighbor_sides[boundary] == 1
                # element in -y direction of boundary
                for l in eachnode(dg), v in eachvariable(equations)
                    boundaries.u[1, v, l, boundary] = u[v, l, nnodes(dg), element]
                end
            else
                # element in +y direction of boundary
                for l in eachnode(dg), v in eachvariable(equations)
                    boundaries.u[2, v, l, boundary] = u[v, l, 1, element]
                end
            end
        end
    end

    return nothing
end

function prolong2boundaries_gpu!(cache, u,
                             mesh::TreeMesh{2}, equations, surface_integral, dg::DG)
    @kernel function internal_prolong2boundaries_gpu!(u, boundaries_u, boundaries_orientations, boundaries_neighbor_sides, boundaries_neighbor_ids, equations, num_nodes)
        boundary = @index(Global)
        element = boundaries_neighbor_ids[boundary]

        if boundaries_orientations[boundary] == 1
            # boundary in x-direction
            if boundaries_neighbor_sides[boundary] == 1
                # element in -x direction of boundary
                for l in 1:num_nodes, v in eachvariable(equations)
                    boundaries_u[1, v, l, boundary] = u[v, num_nodes, l, element]
                end
            else # Element in +x direction of boundary
                for l in 1:num_nodes, v in eachvariable(equations)
                    boundaries_u[2, v, l, boundary] = u[v, 1, l, element]
                end
            end
        else # if orientations[boundary] == 2
            # boundary in y-direction
            if boundaries_neighbor_sides[boundary] == 1
                # element in -y direction of boundary
                for l in 1:num_nodes, v in eachvariable(equations)
                    boundaries_u[1, v, l, boundary] = u[v, l, num_nodes, element]
                end
            else
                # element in +y direction of boundary
                for l in 1:num_nodes, v in eachvariable(equations)
                    boundaries_u[2, v, l, boundary] = u[v, l, 1, element]
                end
            end
        end
    end

    @unpack boundaries = cache
    backend = get_backend(u)

    kernel! = internal_prolong2boundaries_gpu!(backend)
    num_nodes = nnodes(dg)
    num_boundaries = nboundaries(boundaries)

    # CUDA.jl has issues with zero element arrays, therefore skip this kernel since there is no work neccessary anyway
    if (num_boundaries > 0)
        kernel!(u, boundaries.u, boundaries.orientations, boundaries.neighbor_sides, boundaries.neighbor_ids, equations, num_nodes, ndrange=num_boundaries)
        # Ensure that device is finished
        synchronize(backend)
    end

    return nothing
end

# TODO: Taal dimension agnostic
# Trivial, therefore no GPU port needed
function calc_boundary_flux!(cache, t, boundary_condition::BoundaryConditionPeriodic,
                             mesh::TreeMesh{2}, equations, surface_integral, dg::DG)
    @assert isempty(eachboundary(dg, cache))
end

function calc_boundary_flux!(cache, t, boundary_conditions::NamedTuple,
                             mesh::TreeMesh{2}, equations, surface_integral, dg::DG)
    @unpack surface_flux_values = cache.elements
    @unpack n_boundaries_per_direction = cache.boundaries

    # Calculate indices
    lasts = accumulate(+, n_boundaries_per_direction)
    firsts = lasts - n_boundaries_per_direction .+ 1

    # Calc boundary fluxes in each direction
    calc_boundary_flux_by_direction!(surface_flux_values, t, boundary_conditions[1],
                                     have_nonconservative_terms(equations),
                                     equations, surface_integral, dg, cache,
                                     1, firsts[1], lasts[1])
    calc_boundary_flux_by_direction!(surface_flux_values, t, boundary_conditions[2],
                                     have_nonconservative_terms(equations),
                                     equations, surface_integral, dg, cache,
                                     2, firsts[2], lasts[2])
    calc_boundary_flux_by_direction!(surface_flux_values, t, boundary_conditions[3],
                                     have_nonconservative_terms(equations),
                                     equations, surface_integral, dg, cache,
                                     3, firsts[3], lasts[3])
    calc_boundary_flux_by_direction!(surface_flux_values, t, boundary_conditions[4],
                                     have_nonconservative_terms(equations),
                                     equations, surface_integral, dg, cache,
                                     4, firsts[4], lasts[4])
end

function calc_boundary_flux_by_direction!(surface_flux_values::AbstractArray{<:Any, 4},
                                          t,
                                          boundary_condition,
                                          nonconservative_terms::False, equations,
                                          surface_integral, dg::DG, cache,
                                          direction, first_boundary, last_boundary)
    @unpack surface_flux = surface_integral
    @unpack u, neighbor_ids, neighbor_sides, node_coordinates, orientations = cache.boundaries

    @threaded for boundary in first_boundary:last_boundary
        # Get neighboring element
        neighbor = neighbor_ids[boundary]

        for i in eachnode(dg)
            # Get boundary flux
            u_ll, u_rr = get_surface_node_vars(u, equations, dg, i, boundary)
            if neighbor_sides[boundary] == 1 # Element is on the left, boundary on the right
                u_inner = u_ll
            else # Element is on the right, boundary on the left
                u_inner = u_rr
            end
            x = get_node_coords(node_coordinates, equations, dg, i, boundary)
            flux = boundary_condition(u_inner, orientations[boundary], direction, x, t,
                                      surface_flux,
                                      equations)

            # Copy flux to left and right element storage
            for v in eachvariable(equations)
                surface_flux_values[v, i, direction, neighbor] = flux[v]
            end
        end
    end

    return nothing
end

function calc_boundary_flux_by_direction!(surface_flux_values::AbstractArray{<:Any, 4},
                                          t,
                                          boundary_condition,
                                          nonconservative_terms::True, equations,
                                          surface_integral, dg::DG, cache,
                                          direction, first_boundary, last_boundary)
    surface_flux, nonconservative_flux = surface_integral.surface_flux
    @unpack u, neighbor_ids, neighbor_sides, node_coordinates, orientations = cache.boundaries

    @threaded for boundary in first_boundary:last_boundary
        # Get neighboring element
        neighbor = neighbor_ids[boundary]

        for i in eachnode(dg)
            # Get boundary flux
            u_ll, u_rr = get_surface_node_vars(u, equations, dg, i, boundary)
            if neighbor_sides[boundary] == 1 # Element is on the left, boundary on the right
                u_inner = u_ll
            else # Element is on the right, boundary on the left
                u_inner = u_rr
            end
            x = get_node_coords(node_coordinates, equations, dg, i, boundary)
            flux = boundary_condition(u_inner, orientations[boundary], direction, x, t,
                                      surface_flux,
                                      equations)
            noncons_flux = boundary_condition(u_inner, orientations[boundary],
                                              direction, x, t, nonconservative_flux,
                                              equations)

            # Copy flux to left and right element storage
            for v in eachvariable(equations)
                surface_flux_values[v, i, direction, neighbor] = flux[v] +
                                                                 0.5 * noncons_flux[v]
            end
        end
    end

    return nothing
end

function prolong2mortars!(cache, u,
                          mesh::TreeMesh{2}, equations,
                          mortar_l2::LobattoLegendreMortarL2, surface_integral,
                          dg::DGSEM)
    @threaded for mortar in eachmortar(dg, cache)
        large_element = cache.mortars.neighbor_ids[3, mortar]
        upper_element = cache.mortars.neighbor_ids[2, mortar]
        lower_element = cache.mortars.neighbor_ids[1, mortar]

        # Copy solution small to small
        if cache.mortars.large_sides[mortar] == 1 # -> small elements on right side
            if cache.mortars.orientations[mortar] == 1
                # L2 mortars in x-direction
                for l in eachnode(dg)
                    for v in eachvariable(equations)
                        cache.mortars.u_upper[2, v, l, mortar] = u[v, 1, l,
                                                                   upper_element]
                        cache.mortars.u_lower[2, v, l, mortar] = u[v, 1, l,
                                                                   lower_element]
                    end
                end
            else
                # L2 mortars in y-direction
                for l in eachnode(dg)
                    for v in eachvariable(equations)
                        cache.mortars.u_upper[2, v, l, mortar] = u[v, l, 1,
                                                                   upper_element]
                        cache.mortars.u_lower[2, v, l, mortar] = u[v, l, 1,
                                                                   lower_element]
                    end
                end
            end
        else # large_sides[mortar] == 2 -> small elements on left side
            if cache.mortars.orientations[mortar] == 1
                # L2 mortars in x-direction
                for l in eachnode(dg)
                    for v in eachvariable(equations)
                        cache.mortars.u_upper[1, v, l, mortar] = u[v, nnodes(dg), l,
                                                                   upper_element]
                        cache.mortars.u_lower[1, v, l, mortar] = u[v, nnodes(dg), l,
                                                                   lower_element]
                    end
                end
            else
                # L2 mortars in y-direction
                for l in eachnode(dg)
                    for v in eachvariable(equations)
                        cache.mortars.u_upper[1, v, l, mortar] = u[v, l, nnodes(dg),
                                                                   upper_element]
                        cache.mortars.u_lower[1, v, l, mortar] = u[v, l, nnodes(dg),
                                                                   lower_element]
                    end
                end
            end
        end

        # Interpolate large element face data to small interface locations
        if cache.mortars.large_sides[mortar] == 1 # -> large element on left side
            leftright = 1
            if cache.mortars.orientations[mortar] == 1
                # L2 mortars in x-direction
                u_large = view(u, :, nnodes(dg), :, large_element)
                element_solutions_to_mortars!(cache.mortars, mortar_l2, leftright,
                                              mortar, u_large)
            else
                # L2 mortars in y-direction
                u_large = view(u, :, :, nnodes(dg), large_element)
                element_solutions_to_mortars!(cache.mortars, mortar_l2, leftright,
                                              mortar, u_large)
            end
        else # large_sides[mortar] == 2 -> large element on right side
            leftright = 2
            if cache.mortars.orientations[mortar] == 1
                # L2 mortars in x-direction
                u_large = view(u, :, 1, :, large_element)
                element_solutions_to_mortars!(cache.mortars, mortar_l2, leftright,
                                              mortar, u_large)
            else
                # L2 mortars in y-direction
                u_large = view(u, :, :, 1, large_element)
                element_solutions_to_mortars!(cache.mortars, mortar_l2, leftright,
                                              mortar, u_large)
            end
        end
    end

    return nothing
end

function prolong2mortars_gpu!(cache, u,
                          mesh::TreeMesh{2}, equations,
                          mortar_l2::LobattoLegendreMortarL2, surface_integral,
                          dg::DGSEM)
    @kernel function internal_prolong2motars_gpu!(u, mortars_u_upper, mortars_u_lower, mortars_neighbor_ids, mortars_large_sides, mortars_orientations, mortar_l2, equations, num_nodes)
        motar = @index(Global)
        large_element = mortars_neighbor_ids[3, mortar]
        upper_element = mortars_neighbor_ids[2, mortar]
        lower_element = mortars_neighbor_ids[1, mortar]

        # Copy solution small to small
        if mortars_large_sides[mortar] == 1 # -> small elements on right side
            if mortars_orientations[mortar] == 1
                # L2 mortars in x-direction
                for l in 1:num_nodes
                    for v in eachvariable(equations)
                        mortars_u_upper[2, v, l, mortar] = u[v, 1, l,
                                                                   upper_element]
                        mortars_u_lower[2, v, l, mortar] = u[v, 1, l,
                                                                   lower_element]
                    end
                end
            else
                # L2 mortars in y-direction
                for l in 1:num_nodes
                    for v in eachvariable(equations)
                        mortars_u_upper[2, v, l, mortar] = u[v, l, 1,
                                                                   upper_element]
                        mortars_u_lower[2, v, l, mortar] = u[v, l, 1,
                                                                   lower_element]
                    end
                end
            end
        else # large_sides[mortar] == 2 -> small elements on left side
            if mortars_orientations[mortar] == 1
                # L2 mortars in x-direction
                for l in 1:num_nodes
                    for v in eachvariable(equations)
                        mortars_upper[1, v, l, mortar] = u[v, num_nodes, l,
                                                                   upper_element]
                        mortars_u_lower[1, v, l, mortar] = u[v, num_nodes, l,
                                                                   lower_element]
                    end
                end
            else
                # L2 mortars in y-direction
                for l in 1:num_nodes
                    for v in eachvariable(equations)
                        mortars_u_upper[1, v, l, mortar] = u[v, l, num_nodes,
                                                                   upper_element]
                        mortars_u_lower[1, v, l, mortar] = u[v, l, num_nodes,
                                                                   lower_element]
                    end
                end
            end
        end

        # Interpolate large element face data to small interface locations
        if mortars_large_sides[mortar] == 1 # -> large element on left side
            leftright = 1
            if mortars_orientations[mortar] == 1
                # L2 mortars in x-direction
                u_large = view(u, :, num_nodes, :, large_element)
                element_solutions_to_mortars_gpu!(mortars_u_upper, mortars_u_lower, mortar_l2, leftright,
                                              mortar, u_large)
            else
                # L2 mortars in y-direction
                u_large = view(u, :, :, num_nodes, large_element)
                element_solutions_to_mortars_gpu!(mortars_u_upper, mortars_u_lower, mortar_l2, leftright,
                                              mortar, u_large)
            end
        else # large_sides[mortar] == 2 -> large element on right side
            leftright = 2
            if mortars_orientations[mortar] == 1
                # L2 mortars in x-direction
                u_large = view(u, :, 1, :, large_element)
                element_solutions_to_mortars_gpu!(mortars_u_upper, mortars_u_lower, mortar_l2, leftright,
                                              mortar, u_large)
            else
                # L2 mortars in y-direction
                u_large = view(u, :, :, 1, large_element)
                element_solutions_to_mortars_gpu!(mortars_u_upper, mortars_u_lower, mortar_l2, leftright,
                                              mortar, u_large)
            end
        end
    end

    @unpack mortars = cache
    backend = get_backend(u)

    kernel! = internal_prolong2motars_gpu!(backend)
    num_nodes = nnodes(dg)
    num_mortars = nmortars(mortars)

    if (num_mortars > 0)
        kernel!(u, mortars.u_upper, mortars.u_lower, mortars.neighbor_ids, mortars.large_sides, mortars.orientations, mortar_l2, equations, num_nodes, ndrange=num_mortars)
        # Ensure that device is finished
        synchronize(backend)
    end

    return nothing
end

@inline function element_solutions_to_mortars!(mortars,
                                               mortar_l2::LobattoLegendreMortarL2,
                                               leftright, mortar,
                                               u_large::AbstractArray{<:Any, 2})
    multiply_dimensionwise!(view(mortars.u_upper, leftright, :, :, mortar),
                            mortar_l2.forward_upper, u_large)
    multiply_dimensionwise!(view(mortars.u_lower, leftright, :, :, mortar),
                            mortar_l2.forward_lower, u_large)
    return nothing
end

@inline function element_solutions_to_mortars_gpu!(mortars_u_upper, mortars_u_lower,
                                               mortar_l2::LobattoLegendreMortarL2,
                                               leftright, mortar,
                                               u_large::AbstractArray{<:Any, 2})
    multiply_dimensionwise!(view(mortars_u_upper, leftright, :, :, mortar),
                            mortar_l2.forward_upper, u_large)
    multiply_dimensionwise!(view(mortars_u_lower, leftright, :, :, mortar),
                            mortar_l2.forward_lower, u_large)
    return nothing
end

function calc_mortar_flux!(surface_flux_values,
                           mesh::TreeMesh{2},
                           nonconservative_terms::False, equations,
                           mortar_l2::LobattoLegendreMortarL2,
                           surface_integral, dg::DG, cache)
    @unpack surface_flux = surface_integral
    @unpack u_lower, u_upper, orientations = cache.mortars
    @unpack fstar_upper_threaded, fstar_lower_threaded = cache

    @threaded for mortar in eachmortar(dg, cache)
        # Choose thread-specific pre-allocated container
        fstar_upper = fstar_upper_threaded[Threads.threadid()]
        fstar_lower = fstar_lower_threaded[Threads.threadid()]

        # Calculate fluxes
        orientation = orientations[mortar]
        calc_fstar!(fstar_upper, equations, surface_flux, dg, u_upper, mortar,
                    orientation)
        calc_fstar!(fstar_lower, equations, surface_flux, dg, u_lower, mortar,
                    orientation)

        mortar_fluxes_to_elements!(surface_flux_values,
                                   mesh, equations, mortar_l2, dg, cache,
                                   mortar, fstar_upper, fstar_lower)
    end

    return nothing
end

function calc_mortar_flux_gpu!(surface_flux_values,
                           mesh::TreeMesh{2},
                           nonconservative_terms::False, equations,
                           mortar_l2::LobattoLegendreMortarL2,
                           surface_integral, dg::DG, cache)

    # skip for now since empty anyway
    return nothing
end

function calc_mortar_flux!(surface_flux_values,
                           mesh::TreeMesh{2},
                           nonconservative_terms::True, equations,
                           mortar_l2::LobattoLegendreMortarL2,
                           surface_integral, dg::DG, cache)
    surface_flux, nonconservative_flux = surface_integral.surface_flux
    @unpack u_lower, u_upper, orientations, large_sides = cache.mortars
    @unpack fstar_upper_threaded, fstar_lower_threaded = cache

    @threaded for mortar in eachmortar(dg, cache)
        # Choose thread-specific pre-allocated container
        fstar_upper = fstar_upper_threaded[Threads.threadid()]
        fstar_lower = fstar_lower_threaded[Threads.threadid()]

        # Calculate fluxes
        orientation = orientations[mortar]
        calc_fstar!(fstar_upper, equations, surface_flux, dg, u_upper, mortar,
                    orientation)
        calc_fstar!(fstar_lower, equations, surface_flux, dg, u_lower, mortar,
                    orientation)

        # Add nonconservative fluxes.
        # These need to be adapted on the geometry (left/right) since the order of
        # the arguments matters, based on the global SBP operator interpretation.
        # The same interpretation (global SBP operators coupled discontinuously via
        # central fluxes/SATs) explains why we need the factor 0.5.
        # Alternatively, you can also follow the argumentation of Bohm et al. 2018
        # ("nonconservative diamond flux")
        if large_sides[mortar] == 1 # -> small elements on right side
            for i in eachnode(dg)
                # Pull the left and right solutions
                u_upper_ll, u_upper_rr = get_surface_node_vars(u_upper, equations, dg,
                                                               i, mortar)
                u_lower_ll, u_lower_rr = get_surface_node_vars(u_lower, equations, dg,
                                                               i, mortar)
                # Call pointwise nonconservative term
                noncons_upper = nonconservative_flux(u_upper_ll, u_upper_rr,
                                                     orientation, equations)
                noncons_lower = nonconservative_flux(u_lower_ll, u_lower_rr,
                                                     orientation, equations)
                # Add to primary and secondary temporary storage
                multiply_add_to_node_vars!(fstar_upper, 0.5, noncons_upper, equations,
                                           dg, i)
                multiply_add_to_node_vars!(fstar_lower, 0.5, noncons_lower, equations,
                                           dg, i)
            end
        else # large_sides[mortar] == 2 -> small elements on the left
            for i in eachnode(dg)
                # Pull the left and right solutions
                u_upper_ll, u_upper_rr = get_surface_node_vars(u_upper, equations, dg,
                                                               i, mortar)
                u_lower_ll, u_lower_rr = get_surface_node_vars(u_lower, equations, dg,
                                                               i, mortar)
                # Call pointwise nonconservative term
                noncons_upper = nonconservative_flux(u_upper_rr, u_upper_ll,
                                                     orientation, equations)
                noncons_lower = nonconservative_flux(u_lower_rr, u_lower_ll,
                                                     orientation, equations)
                # Add to primary and secondary temporary storage
                multiply_add_to_node_vars!(fstar_upper, 0.5, noncons_upper, equations,
                                           dg, i)
                multiply_add_to_node_vars!(fstar_lower, 0.5, noncons_lower, equations,
                                           dg, i)
            end
        end

        mortar_fluxes_to_elements!(surface_flux_values,
                                   mesh, equations, mortar_l2, dg, cache,
                                   mortar, fstar_upper, fstar_lower)
    end

    return nothing
end

@inline function calc_fstar!(destination::AbstractArray{<:Any, 2}, equations,
                             surface_flux, dg::DGSEM,
                             u_interfaces, interface, orientation)
    for i in eachnode(dg)
        # Call pointwise two-point numerical flux function
        u_ll, u_rr = get_surface_node_vars(u_interfaces, equations, dg, i, interface)
        flux = surface_flux(u_ll, u_rr, orientation, equations)

        # Copy flux to left and right element storage
        set_node_vars!(destination, flux, equations, dg, i)
    end

    return nothing
end

@inline function mortar_fluxes_to_elements!(surface_flux_values,
                                            mesh::TreeMesh{2}, equations,
                                            mortar_l2::LobattoLegendreMortarL2,
                                            dg::DGSEM, cache,
                                            mortar, fstar_upper, fstar_lower)
    large_element = cache.mortars.neighbor_ids[3, mortar]
    upper_element = cache.mortars.neighbor_ids[2, mortar]
    lower_element = cache.mortars.neighbor_ids[1, mortar]

    # Copy flux small to small
    if cache.mortars.large_sides[mortar] == 1 # -> small elements on right side
        if cache.mortars.orientations[mortar] == 1
            # L2 mortars in x-direction
            direction = 1
        else
            # L2 mortars in y-direction
            direction = 3
        end
    else # large_sides[mortar] == 2 -> small elements on left side
        if cache.mortars.orientations[mortar] == 1
            # L2 mortars in x-direction
            direction = 2
        else
            # L2 mortars in y-direction
            direction = 4
        end
    end
    surface_flux_values[:, :, direction, upper_element] .= fstar_upper
    surface_flux_values[:, :, direction, lower_element] .= fstar_lower

    # Project small fluxes to large element
    if cache.mortars.large_sides[mortar] == 1 # -> large element on left side
        if cache.mortars.orientations[mortar] == 1
            # L2 mortars in x-direction
            direction = 2
        else
            # L2 mortars in y-direction
            direction = 4
        end
    else # large_sides[mortar] == 2 -> large element on right side
        if cache.mortars.orientations[mortar] == 1
            # L2 mortars in x-direction
            direction = 1
        else
            # L2 mortars in y-direction
            direction = 3
        end
    end

    # TODO: Taal performance
    # for v in eachvariable(equations)
    #   # The code below is semantically equivalent to
    #   # surface_flux_values[v, :, direction, large_element] .=
    #   #   (mortar_l2.reverse_upper * fstar_upper[v, :] + mortar_l2.reverse_lower * fstar_lower[v, :])
    #   # but faster and does not allocate.
    #   # Note that `true * some_float == some_float` in Julia, i.e. `true` acts as
    #   # a universal `one`. Hence, the second `mul!` means "add the matrix-vector
    #   # product to the current value of the destination".
    #   @views mul!(surface_flux_values[v, :, direction, large_element],
    #               mortar_l2.reverse_upper, fstar_upper[v, :])
    #   @views mul!(surface_flux_values[v, :, direction, large_element],
    #               mortar_l2.reverse_lower,  fstar_lower[v, :], true, true)
    # end
    # The code above could be replaced by the following code. However, the relative efficiency
    # depends on the types of fstar_upper/fstar_lower and dg.l2mortar_reverse_upper.
    # Using StaticArrays for both makes the code above faster for common test cases.
    multiply_dimensionwise!(view(surface_flux_values, :, :, direction, large_element),
                            mortar_l2.reverse_upper, fstar_upper,
                            mortar_l2.reverse_lower, fstar_lower)

    return nothing
end

function calc_surface_integral!(du, u, mesh::Union{TreeMesh{2}, StructuredMesh{2}},
                                equations, surface_integral::SurfaceIntegralWeakForm,
                                dg::DG, cache)
    @unpack boundary_interpolation = dg.basis
    @unpack surface_flux_values = cache.elements

    # Note that all fluxes have been computed with outward-pointing normal vectors.
    # Access the factors only once before beginning the loop to increase performance.
    # We also use explicit assignments instead of `+=` to let `@muladd` turn these
    # into FMAs (see comment at the top of the file).
    factor_1 = boundary_interpolation[1, 1]
    factor_2 = boundary_interpolation[nnodes(dg), 2]
    @threaded for element in eachelement(dg, cache)
        for l in eachnode(dg)
            for v in eachvariable(equations)
                # surface at -x
                du[v, 1, l, element] = (du[v, 1, l, element] -
                                        surface_flux_values[v, l, 1, element] *
                                        factor_1)

                # surface at +x
                du[v, nnodes(dg), l, element] = (du[v, nnodes(dg), l, element] +
                                                 surface_flux_values[v, l, 2, element] *
                                                 factor_2)

                # surface at -y
                du[v, l, 1, element] = (du[v, l, 1, element] -
                                        surface_flux_values[v, l, 3, element] *
                                        factor_1)

                # surface at +y
                du[v, l, nnodes(dg), element] = (du[v, l, nnodes(dg), element] +
                                                 surface_flux_values[v, l, 4, element] *
                                                 factor_2)
            end
        end
    end

    return nothing
end

end #@muladd

function calc_surface_integral_gpu!(du, u, mesh::Union{TreeMesh{2}, StructuredMesh{2}},
                                equations, surface_integral::SurfaceIntegralWeakForm,
                                dg::DG, cache)
    @kernel function internal_calc_surface_integral_gpu!(du, boundary_interpolation, surface_flux_values, num_nodes)
        element = @index(Global)

        # Note that all fluxes have been computed with outward-pointing normal vectors.
        # Access the factors only once before beginning the loop to increase performance.
        # We also use explicit assignments instead of `+=` to let `@muladd` turn these
        # into FMAs (see comment at the top of the file).
        factor_1 = boundary_interpolation[1, 1]
        factor_2 = boundary_interpolation[num_nodes, 2]

        for l in 1:num_nodes
            for v in eachvariable(equations)
                # surface at -x
                du[v, 1, l, element] = (du[v, 1, l, element] -
                                        surface_flux_values[v, l, 1, element] *
                                        factor_1)

                # surface at +x
                du[v, num_nodes, l, element] = (du[v, num_nodes, l, element] +
                                                 surface_flux_values[v, l, 2, element] *
                                                 factor_2)

                # surface at -y
                du[v, l, 1, element] = (du[v, l, 1, element] -
                                        surface_flux_values[v, l, 3, element] *
                                        factor_1)

                # surface at +y
                du[v, l, num_nodes, element] = (du[v, l, num_nodes, element] +
                                                 surface_flux_values[v, l, 4, element] *
                                                 factor_2)
            end
        end
    end

    @unpack boundary_interpolation = dg.basis
    @unpack surface_flux_values = cache.elements
    backend = get_backend(u)

    kernel! = internal_calc_surface_integral_gpu!(backend)
    num_nodes = nnodes(dg)
    num_elements = nelements(cache.elements)

    kernel!(du, boundary_interpolation, surface_flux_values, num_nodes, ndrange=num_elements)
    # Ensure that device is finished
    synchronize(backend)

    return nothing
end

@muladd begin

function apply_jacobian!(du, mesh::TreeMesh{2},
                         equations, dg::DG, cache)
    @threaded for element in eachelement(dg, cache)
        factor = -cache.elements.inverse_jacobian[element]

        for j in eachnode(dg), i in eachnode(dg)
            for v in eachvariable(equations)
                du[v, i, j, element] *= factor
            end
        end
    end

    return nothing
end

end # @muladd 

function apply_jacobian_gpu!(du, mesh::TreeMesh{2},
                         equations, dg::DG, cache)
    @kernel function internal_apply_jacobian_gpu!(du, inverse_jacobian, equations, num_nodes)
        element = @index(Global)
        factor = -inverse_jacobian[element]

        for j in 1:num_nodes, i in 1:num_nodes
            for v in eachvariable(equations)
                du[v, i, j, element] *= factor
            end
        end
    end

    @unpack inverse_jacobian = cache.elements
    backend = get_backend(du)

    kernel! = internal_apply_jacobian_gpu!(backend)

    num_nodes = nnodes(dg)
    num_elements = nelements(cache.elements)

    kernel!(du, inverse_jacobian, equations, num_nodes, ndrange=num_elements)

    synchronize(backend)

    return nothing
end

@muladd begin

# TODO: Taal dimension agnostic
function calc_sources!(du, u, t, source_terms::Nothing,
                       equations::AbstractEquations{2}, dg::DG, cache)
    return nothing
end

function calc_sources_gpu!(du, u, t, source_terms::Nothing,
                       equations::AbstractEquations{2}, dg::DG, cache)
    return nothing
end

function calc_sources!(du, u, t, source_terms,
                       equations::AbstractEquations{2}, dg::DG, cache)
    @threaded for element in eachelement(dg, cache)
        for j in eachnode(dg), i in eachnode(dg)
            u_local = get_node_vars(u, equations, dg, i, j, element)
            x_local = get_node_coords(cache.elements.node_coordinates, equations, dg, i,
                                      j, element)
            du_local = source_terms(u_local, x_local, t, equations)
            add_to_node_vars!(du, du_local, equations, dg, i, j, element)
        end
    end

    return nothing
end
end # @muladd
