function [best, best_cost, history] = ies_pso(names, lb, ub, p, mode, solver, opts)
% IES_PSO  论文 5.2 节：多设备容量同时寻优（粒子群算法）
%
%   [best, cost, history] = ies_pso(names, lb, ub, p, mode, solver, opts)
%     names : 容量参数名，如 {'PGT_max','PEL_max','HMR_max','HHFC_max','PGB_max','PWHB_max'}
%     lb/ub : 各容量的上下限（行向量）
%     opts  : 结构体，可选字段 n_particles（默认 30）、iters（60）、seed（0）、
%             w（0.7）、c1（1.5）、c2（1.5）、verbose（true）
%   每个粒子的适应度就是该容量组合下第 4 节调度模型的最优总成本。
%   best 为最优容量结构体，可直接传给 ies_capacity_cost。

if nargin < 4 || isempty(p),    p = ies_params(); end
if nargin < 5 || isempty(mode), mode = 'paper';   end
if nargin < 6,                  solver = '';      end
if nargin < 7,                  opts = struct();  end
o = struct('n_particles', 30, 'iters', 60, 'seed', 0, 'w', 0.7, 'c1', 1.5, 'c2', 1.5, 'verbose', true);
fn = fieldnames(opts);
for k = 1:numel(fn), o.(fn{k}) = opts.(fn{k}); end

rand('twister', o.seed);    %#ok<RAND>  MATLAB 与 Octave 通用的设定随机种子写法
lb = lb(:)';  ub = ub(:)';
D = numel(names);  N = o.n_particles;
vmax = 0.2 * (ub - lb);
x = repmat(lb, N, 1) + rand(N, D) .* repmat(ub - lb, N, 1);
vel = zeros(N, D);
pbest = x;  pcost = arrayfun(@(i) fitness(x(i, :)), (1:N)');
[gcost, g] = min(pcost);  gbest = pbest(g, :);
history = gcost;
for it = 1:o.iters
    r1 = rand(N, D);  r2 = rand(N, D);
    vel = o.w * vel + o.c1 * r1 .* (pbest - x) + o.c2 * r2 .* (repmat(gbest, N, 1) - x);
    vel = max(min(vel, repmat(vmax, N, 1)), -repmat(vmax, N, 1));
    x = max(min(x + vel, repmat(ub, N, 1)), repmat(lb, N, 1));
    cost = arrayfun(@(i) fitness(x(i, :)), (1:N)');
    better = cost < pcost;
    pbest(better, :) = x(better, :);  pcost(better) = cost(better);
    [m, g] = min(pcost);
    if m < gcost, gcost = m; gbest = pbest(g, :); end
    history(end + 1) = gcost; %#ok<AGROW>
    if o.verbose, fprintf('  PSO 第 %2d/%d 代：最低总成本 %.1f\n', it, o.iters, gcost); end
end
best = cell2struct(num2cell(gbest), names, 2);
best_cost = gcost;

    function c = fitness(xi)
        c = ies_capacity_cost(cell2struct(num2cell(xi), names, 2), p, mode, solver);
    end
end
