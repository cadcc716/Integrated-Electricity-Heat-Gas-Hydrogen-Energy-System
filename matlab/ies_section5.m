function out = ies_section5(p, mode, solver)
% IES_SECTION5  第 5 节：在论文 Table 4、Table 6 的优化容量下求解，比较成本相对基准的降幅
%
%   out = ies_section5(p, mode, solver)
%   论文与本模型的基准成本不同，因此比较各容量方案相对各自基准的降幅。

if nargin < 1 || isempty(p),    p = ies_params(); end
if nargin < 2 || isempty(mode), mode = 'paper';   end
if nargin < 3,                  solver = '';      end

paper_base = 847510.4;
% 论文 Table 4：单设备容量寻优结果；最后一行为 Table 6 六设备同时寻优
label = {'GT = 254.1259', 'EL = 60.6105', 'MR = 72.7329', 'HFC = 0', ...
         'GB = 81.7263', 'WHB = 81.2426', 'Table 6 六设备'};
caps = {struct('PGT_max', 254.1259), struct('PEL_max', 60.6105), struct('HMR_max', 72.7329), ...
        struct('HHFC_max', 0), struct('PGB_max', 81.7263), struct('PWHB_max', 81.2426), ...
        struct('PGT_max', 162.8317, 'PEL_max', 65.5134, 'HMR_max', 1127.2, ...
               'HHFC_max', 0, 'PGB_max', 0, 'PWHB_max', 87.9743)};
paper_cost = [843440, 570690, 830750, 847060, 770170, 813800, 446106.7];

base = ies_capacity_cost(struct(), p, mode, solver);
ours = zeros(size(paper_cost));
fprintf('\n第 5 节：论文优化容量下的成本变化（相对各自基准）\n');
fprintf('%-16s %14s %10s %14s %10s\n', '容量方案', '本模型总成本', '降幅 %', '论文总成本', '降幅 %');
for k = 1:numel(caps)
    ours(k) = ies_capacity_cost(caps{k}, p, mode, solver);
    fprintf('%-16s %14.1f %10.2f %14.1f %10.2f\n', label{k}, ours(k), (ours(k) / base - 1) * 100, ...
            paper_cost(k), (paper_cost(k) / paper_base - 1) * 100);
end
out = struct('label', {label}, 'ours', ours, 'ours_change', (ours / base - 1) * 100, ...
             'paper', paper_cost, 'paper_change', (paper_cost / paper_base - 1) * 100, 'base', base);
end
