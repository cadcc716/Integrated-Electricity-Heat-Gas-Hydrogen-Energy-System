%% 电–热–气–氢综合能源系统优化调度与容量配置 —— 论文复现（MATLAB + YALMIP）
% Wang J, Liu H, Xu C. Resource scheduling and capacity allocation optimization of an
% integrated electricity-heat-gas-hydrogen energy system. Energy, 2025, 337: 138683.
%
% 依赖：YALMIP（https://yalmip.github.io）和一个 MILP 求解器（Gurobi / CPLEX / intlinprog）。
% 与 Python 版 ies_model.py 是同一个模型，默认参数下结果一致。
clc; clear; close all;

solver = 'gurobi';    % 'gurobi' | 'cplex' | 'intlinprog' | 'glpk' | '' 由 YALMIP 自动选择

%% 1. 第 4 节：24 h 优化调度
p = ies_params();                       % 默认参数复现论文结果；ies_params('literal') 为公式字面写法
res = ies_solve(p, 'paper', solver);    % 储能口径：'paper' | 'zero_start' | 'cyclic'
ies_report(res);
ies_plot(res, 'pic_matlab');            % 论文 Fig.4(a)–(f)，PNG 保存到 pic_matlab/

%% 2. 不同口径对比
modes = {'paper', 'zero_start', 'cyclic'};
fprintf('\n不同储能口径的总成本：\n');
for k = 1:numel(modes)
    r = ies_solve(p, modes{k}, solver);
    fprintf('  %-11s %12.1f\n', modes{k}, r.total);
end
r = ies_solve(ies_params('literal'), 'paper', solver);
fprintf('  %-11s %12.1f   （按论文公式字面实现）\n', 'literal', r.total);

%% 3. 第 5 节：论文优化容量下的成本变化（Table 4、Table 6）
ies_section5(p, 'paper', solver);

%% 4. 第 5 节：六设备容量同时寻优（PSO，对应论文 Table 6）
% 每次适应度计算都要求解一次调度模型，YALMIP 建模较慢，完整运行可能需要较长时间，
% 可先把 n_particles / iters 调小试跑。
run_pso = false;
if run_pso
    names = {'PGT_max', 'PEL_max', 'HMR_max', 'HHFC_max', 'PGB_max', 'PWHB_max'};
    lb = [0, 0, 0, 0, 0, 0];
    ub = [600, 100, 2000, 50, 200, 200];
    [best, best_cost] = ies_pso(names, lb, ub, p, 'paper', solver, ...
                                struct('n_particles', 30, 'iters', 60, 'seed', 0));
    disp(best);
    fprintf('PSO 最低总成本：%.1f（论文 Table 6：446106.7）\n', best_cost);
end
