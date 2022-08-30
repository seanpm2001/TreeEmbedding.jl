import Base.push!

# Methods for altering arrays containing nodes (children) depending on the chosen Loss-function
# FNN, CCM & Prediction

"""
    push!(children::Union{Array{Node,1},Nothing}, n::EmbeddingPars, Γ::AbstractLoss, current_node::AbstractTreeElement)    

Adds new `children`/nodes to the tree below `current_node` with embedding parameters `n`, according to the loss `Γ`. 
""" 
function push!(children::Array{Node,1}, n::EmbeddingPars, Γ::AbstractLoss, current_node::AbstractTreeElement)
    Base.push!(children, Node(n, [get_τs(current_node); τ(n)], [get_ts(current_node); t(n)], nothing))
end

"""
    init_embedding_params(Γ::AbstractLoss, N::Int)

Return the initial embedding parameters and loss function value, based on the chosen loss function. Every new loss should get a new function, otherwise the default (0, 1, 99999, nothing) is returned. 
"""
function init_embedding_params(Γ::AbstractLoss, N::Int)
    return [EmbeddingPars(τ=0, t=1, L=99999f0)]
end

"""
    get_potential_delays(optimalg::AbstractMCDTSOptimGoal, Ys::Dataset, τs, w::Int, τ_vals,
                    ts_vals, L_old ; kwargs...]) → embedding_pars, is_converged

Computes a vector of potential embedding parameters: the potential delay `τ_pot` and 
time series values `ts_pot`, which would each result in a potential Loss-statistic value 
`L_pot`, by using an embedding method specified in `optimalg` [^Kraemer2022] (see [`MCDTSOptimGoal`](@ref))
and for a range of possible delay values `τs`. These embedding parameters are stored in the returned
`embedding_pars` object (see [`EmbeddingPars`](@ref)). Additionally, `is_converged` (`::Bool`) indicates 
whether the chosen Loss-function can be minimized further or not.
    
The input dataset `Ys` can be multivariate. `w` is the Theiler window (neighbors in time with index `w` close
to the point, that are excluded from being true neighbors. `w=0` means to
exclude only the point itself, and no temporal neighbors. In case of multivariate
time series input choose `w` as the maximum of all `wᵢ's`. `τ_vals` and `ts_vals`
describe the embedding up to the current embedding cycle.

## Keyword arguments
* See [`mcdts_embedding`](@ref) for a list of all keywords.
"""
function get_potential_delays(optimalg::AbstractMCDTSOptimGoal, Yss::Union{Dataset{D,T},Vector{T}},
                τs, w::Int, τ_vals, ts_vals, L_old; kwargs...) where {D, T}

    Ys = DelayEmbeddings.standardize(Dataset(Yss))

    # compute actual embedding trajectory Y_act
    Y_act = embedding_trajectory(optimalg.Γ, Ys, τ_vals, ts_vals)

    # compute potential delay values with corresponding time series values and
    # Loss-values
    embedding_pars = embedding_cycle(optimalg, Y_act, Ys, τs, w, τ_vals, ts_vals, L_old; kwargs...)

    if isempty(embedding_pars)
        flag = true
        return EmbeddingPars[], flag
    end

    embedding_pars, is_converged = get_embedding_params_according_to_loss(optimalg.Γ,
                                            embedding_pars, L_old)

    return embedding_pars, is_converged
end

"""
    embedding_trajectory(Γ::AbstractLoss, Y, τ_vals, ts_vals)

Compute actual embedding trajectory with `DelayEmbeddings.genembed`
"""
embedding_trajectory(Γ::AbstractLoss, Ys, τ_vals, ts_vals) = genembed(Ys, τ_vals, ts_vals)

"""
    get_embedding_params_according_to_loss(Γ::AbstractLoss, τ_pot, ts_popt, L_pot, L_old) -> embedding_par, is_converged

Helper function for [`get_potential_delays`](@ref). Computes the potential
delay-, time series- and according Loss-values with respect to the actual loss
in the current embedding cycle, all stored in an `embedding_pars`-object (see [`EmbeddingPars`](@ref)). 
`is_converged` (`::Bool`) indicates whether the chosen Loss-function can be minimized further or not.
"""
function get_embedding_params_according_to_loss(Γ::AbstractLoss, embedding_pars::Vector{EmbeddingPars}, L_old)
    T = threshold(Γ)
    L_pot = L.(embedding_pars)

    if (minimum(L_pot) ≥ L_old)
        return EmbeddingPars[], true
    elseif (minimum(L_pot) ≤ T)
        ind = L_pot .< L_old
        return embedding_pars[ind], true
    else
        ind = L_pot .< L_old
        return embedding_pars[ind], false
    end
end

"""
    embedding_cycle(optimalg::AbstractMCDTSOptimGoal, Y_act, Ys, τs,
                                    w, τ_vals, ts_vals; kwargs...) -> embedding_params

Perform a potential embedding cycle from the multi- or univariate Dataset `Ys`.
Return the possible delays `τ_pot`, the associated time series `ts_pot` and
the corresponding Loss-statistic-values, `L_pot` for each peak, i.e. for each
(`τ_pot`, `ts_pot`) pair. These embedding parameters are stored in the returned
`embedding_params` object (see [`EmbeddingPars`](@ref)).
"""
function embedding_cycle(optimalg::AbstractMCDTSOptimGoal, Y_act, Ys, τs,
                                                    w, τ_vals, ts_vals, L_old; kwargs...)

    # Compute Delay-pre-selection method according to `optimalg.Λ`
    delay_pre_selection_statistic = get_delay_statistic(optimalg.Λ, Ys, τs, w, τ_vals, ts_vals; kwargs... )

    # update τ_vals, ts_vals, Ls, ε★s
    embedding_params = pick_possible_embedding_params(optimalg.Γ, optimalg.Λ, delay_pre_selection_statistic, Y_act, Ys, τs, w, τ_vals, ts_vals, L_old; kwargs...)

    return embedding_params
end


"""
    Compute all possible τ-values (and according time series numbers) and their
    corresponding Loss-statistics for the input delay_pre_selection_statistic `dps`.
"""
function pick_possible_embedding_params(Γ::AbstractLoss, Λ::AbstractDelayPreselection, dps, Y_act::Dataset{D, T}, Ys, τs, w::Int, τ_vals, ts_vals, L_old; kwargs...) where {D, T}

    embedding_pars = EmbeddingPars[]
    for ts = 1:size(Ys,2)
        # compute loss and its corresponding index w.r.t `delay_pre_selection_statistic`

        # zero-padding of dps in order to also cover τ=0 (important for the multivariate case)
        L_trials, max_idx, temp = compute_loss(Γ, Λ, vec([0; dps[:,ts]]), Y_act, Ys, τs, w, ts, τ_vals, ts_vals; L_old = L_old, kwargs...)
        if isempty(max_idx)
            tt = max_idx
        else
            tt = τs[max_idx.-1]
            if typeof(tt)==Int
                tt = [tt]
            end
        end
        for i_trial in eachindex(L_trials)
            embedding_par = EmbeddingPars(τ=tt[i_trial], t=ts, L=L_trials[i_trial], temp=temp)
            Base.push!(embedding_pars, embedding_par)
        end
    end
 
    return embedding_pars
end

"""
    Compute the loss of a given delay-preselection statistic `dps` and the loss
    determined by `optimalg.Γ`.
"""
compute_loss
