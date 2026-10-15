function cost = ies_capacity_cost(caps, p, mode, solver)
% IES_CAPACITY_COST  给定设备容量下最优调度的总成本（第 5 节的适应度函数）
%
%   cost = ies_capacity_cost(struct('PEL_max', 60.6), p, mode, solver)
%   caps 的字段名为 PGT_max / PEL_max / HMR_max / HHFC_max / PGB_max / PWHB_max，
%   求解失败时返回 Inf。

if nargin < 2 || isempty(p),    p = ies_params(); end
if nargin < 3 || isempty(mode), mode = 'paper';   end
if nargin < 4,                  solver = '';      end
names = fieldnames(caps);
for k = 1:numel(names)
    p.(names{k}) = caps.(names{k});
end
res = ies_solve(p, mode, solver);
if res.ok, cost = res.total; else, cost = Inf; end
end
