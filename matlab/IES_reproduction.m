%% =====================================================================
%  电–热–气–氢综合能源系统优化调度与容量配置 —— 论文复现（MATLAB + YALMIP，单文件版）
%
%  Wang J, Liu H, Xu C. Resource scheduling and capacity allocation optimization of an
%  integrated electricity-heat-gas-hydrogen energy system. Energy, 2025, 337: 138683.
%  https://doi.org/10.1016/j.energy.2025.138683
%
%  依赖：MATLAB R2016b 及以上、YALMIP（https://yalmip.github.io）、一个 MILP 求解器
%        （Gurobi / CPLEX / intlinprog）。直接运行本文件即可，不需要其他 .m 文件。
%
%  文件结构：
%    第 0 段  用户设置（求解器、储能口径、是否画图、是否运行 PSO）
%    第 1 段  数据与参数（论文 Table 1–3、Fig.2–3）           → 函数 ies_params
%    第 2 段  第 4 节 24 h 优化调度（设备/储能/平衡/碳交易约束）→ 函数 ies_solve
%    第 3 段  结果输出与论文对比                               → 函数 ies_report
%    第 4 段  画图（论文 Fig.4(a)–(f)）                         → 函数 ies_plot
%    第 5 段  不同口径对比
%    第 6 段  第 5 节：论文 Table 4/6 容量方案                  → 函数 ies_section5
%    第 7 段  第 5 节：六设备容量 PSO 寻优（默认关闭）          → 函数 ies_pso
%    文件末尾  全部函数定义
%
%  默认参数复现论文报告的结果，与论文公式字面写法不同的三处（依据见 README）：
%    1. 储能首末条件按作者实际实现（S_n(1) = 0，第 1 时段的强制充电不计入库存）
%    2. 富余碳配额按 2λ 出售（sell_factor = 2）
%    3. GT/GB/WHB/EL/MR/HFC 的运维成本按 α_i × 额定容量计（om_basis = 'capacity'）
%  ies_params('literal') 给出完全按论文公式字面实现的参数。
%  =====================================================================
clc; clear; close all;

%% 0. 用户设置
solver   = 'gurobi';    % 'gurobi' | 'cplex' | 'intlinprog' | '' 由 YALMIP 自动选择
es_mode  = 'paper';     % 储能口径：'paper'（默认，论文作者的实现）| 'zero_start' | 'cyclic'
plot_dir = 'pic_matlab';% 结果图保存目录；设为 '' 则只显示不保存
run_compare  = true;    % 第 5 段：不同口径对比
run_section5 = true;    % 第 6 段：论文 Table 4/6 容量方案
run_pso      = false;   % 第 7 段：六设备 PSO（需求解约 1,800 次，耗时较长）

if isempty(which('sdpvar'))
    error('未找到 YALMIP：请先下载 YALMIP 并用 addpath(genpath(''YALMIP 所在目录'')) 加入路径');
end

%% 1. 数据与参数
p = ies_params();                 % 修改参数示例：p = ies_params('PEL_max', 60.6);

%% 2. 第 4 节：24 h 优化调度
res = ies_solve(p, es_mode, solver);
if ~res.ok
    error('求解失败：%s', res.info);
end

%% 3. 结果输出与论文对比
ies_report(res);

%% 4. 画图（论文 Fig.4(a)–(f)）
ies_plot(res, plot_dir);

%% 5. 不同口径对比
if run_compare
    fprintf('\n不同口径的总成本：\n');
    modes = {'paper', 'zero_start', 'cyclic'};
    for k = 1:numel(modes)
        r = ies_solve(p, modes{k}, solver);
        fprintf('  %-11s %12.1f\n', modes{k}, r.total);
    end
    r = ies_solve(ies_params('literal'), 'paper', solver);
    fprintf('  %-11s %12.1f   （按论文公式字面实现）\n', 'literal', r.total);
end

%% 6. 第 5 节：论文 Table 4、Table 6 容量方案下的成本变化
if run_section5
    ies_section5(p, es_mode, solver);
end

%% 7. 第 5 节：六设备容量同时寻优（PSO，对应论文 Table 6）
if run_pso
    names = {'PGT_max', 'PEL_max', 'HMR_max', 'HHFC_max', 'PGB_max', 'PWHB_max'};
    lb = [0, 0, 0, 0, 0, 0];
    ub = [600, 100, 2000, 50, 200, 200];
    [best, best_cost] = ies_pso(names, lb, ub, p, es_mode, solver, ...
                                struct('n_particles', 30, 'iters', 60, 'seed', 0));
    disp(best);
    fprintf('PSO 最低总成本：%.1f（论文 Table 6：446106.7）\n', best_cost);
    res_opt = ies_solve(ies_params_with(p, best), es_mode, solver);
    ies_report(res_opt);
end

%% =====================================================================
%  以下为函数定义
%  =====================================================================

%% ---------------------------------------------------------------------
%  数据与参数
%  ---------------------------------------------------------------------
function p = ies_params(varargin)
% IES_PARAMS  电–热–气–氢综合能源系统参数（论文 Table 1–3、Fig.2–3）
%
%   p = ies_params()                     默认参数，复现论文报告的结果
%   p = ies_params('literal')            完全按论文公式字面实现（出售价 λ、运维按出力计）
%   p = ies_params('PEL_max', 60.6)      修改任意参数（可与 'literal' 连用）
%
% 默认参数与论文公式字面写法不同的两处（依据见 README）：
%   sell_factor = 2        论文报告的碳交易收益恰好等于 2λ × 富余配额
%   om_basis = 'capacity'  GT/GB/WHB/EL/MR/HFC 运维成本按 α_i × 额定容量计

p.T = 24;           % 调度时段数
p.dt = 1;           % 时段长度（h）

% ---- 燃气轮机 GT ----
p.PGT_max = 580;    p.ramp_GT = 0.2;   p.eta_GT = 0.35;   p.eta_loss = 0.1;   p.a_GT = 12.5;
% ---- 燃气锅炉 GB ----
p.PGB_max = 1000;   p.ramp_GB = 0.2;   p.eta_GB = 0.75;   p.a_GB = 85;
% ---- 余热锅炉 WHB ----
p.PWHB_max = 600;   p.eta_WHB = 0.75;  p.a_WHB = 65;
% ---- 电解槽 EL ----
p.PEL_max = 5;      p.ramp_EL = 0.2;   p.eta_EL = 0.75;   p.a_EL = 25;
p.meh = 0.03954;    % 氢气热值（MWh/kg）
% ---- 甲烷发生器 MR ----
p.HMR_max = 1000;   p.ramp_MR = 0.2;   p.eta_MR = 0.6;    p.a_MR = 19;
p.theta = 0.00135;  % MR 的 CO2 利用系数（t/kg）
% ---- 氢燃料电池 HFC ----
p.HHFC_max = 25;    p.ramp_HFC = 0.2;  p.eta_HFC = 0.95;
p.eta_HFC_e = 0.8;  p.eta_HFC_h = 0.15; p.a_HFC = 18;
% ---- 碳捕集 CCS ----
p.eta_CCS = 0.65;   p.e_ccs = 0.269;   p.k_cs = 1.4;      p.a_CCS = 55;   % a_CCS 按耗电量计
% ---- 风电 / 光伏 ----
p.a_WT = 70;        p.a_PV = 32;       % 按实际出力计
p.pen_WT = 200;     p.pen_PV = 200;    % 弃风弃光惩罚 ¥/MWh
% ---- 碳配额系数与实际排放系数（kg/kWh = t/MWh）----
p.k_buy = 0.68;     p.k_GT = 0.612;    p.k_GB = 0.306;
p.k_buy_a = 1.08;   p.k_GT_e = 0.195;  p.k_GT_h = 0.39;   p.k_GB_a = 0.195;
% ---- 阶梯碳交易 ----
p.lam = 250;        p.l_step = 100;    p.alpha_step = 0.25;
p.sell_factor = 2;          % 富余配额出售价 = sell_factor·λ（Eq.(11) 字面为 1）
p.om_basis = 'capacity';    % 'capacity' | 'energy'（Eq.(13) 字面写法）
% ---- 能源价格 ----
p.price_gas = 350;  p.price_H2 = 1500;  p.price_heat = 1000;   % ¥/MWh
p.price_elec = [343.8*ones(1,7), 680*ones(1,4), 811*ones(1,3), 680*ones(1,3), ...
                811*ones(1,5), 380*ones(1,2)]';                % Table 3
% ---- 外购上限（论文未给出数值，Inf 表示不限）----
p.buy_max_e = Inf;  p.buy_max_h = Inf;  p.buy_max_g = Inf;  p.buy_max_H = Inf;
% ---- 储能（Table 2，Eq.(19)–(20)）----
% 所有限值都按 Pmax_n 的比例给出：充放功率 ≤ 0.3·Pmax_n，库存 0.2~0.9·Pmax_n，
% 首时段充电 ≥ 0.2·Pmax_n。Table 2 的数值就是这些比例的结果，不要再乘 0.3。
p.ES.name    = {'电储能', '热储能', '气储能', '氢储能'};
p.ES.p_max   = [200, 200, 100, 1000];     % Pmax_n（MWh 或 kg）
p.ES.eta_cha = [0.95, 0.95, 0.95, 0.95];
p.ES.eta_dis = [0.95, 0.95, 0.95, 0.95];
p.ES.mu      = [0.001, 0, 0, 0];          % 自放电率
p.ES.alpha   = [18, 16, 16, 16];          % 运维成本，按充放电量计
p.ES.degrade = [true, false, false, false];
p.deg = [200, 4.168e-4, 1.9984e-7, 0.0332];   % Eq.(19) 的 a, b, c, d
% ---- 风光出力（读自 Fig.2）与负荷（读自 Fig.3）----
p.WT_avail = [20 33 36 46 47 43 40 50 38 34 48 31 38 29 11 8 32 47 33 42 52 50 59 42.5]';
p.PV_avail = [0 0 0 0 0 0 0 0 0 17 30 40 45 46 43 33 21 8 0 0 0 0 0 0]';
p.load_e   = [15 25 26 28 28 32 35 41 43 49 55 68 66 56 43 42 47 51 53 54 50 39 30 27]';
p.load_h   = [45 24 38 48 51 58 43 58 68 83 80 84 70 68 65 62 65 88 50 48 45 55 63 50]';
p.load_H   = [80 66 60 50 50 55 55 100 152 136 80 70 70 70 90 90 80 70 70 70 70 70 70 70]';  % kg/h
p.load_g   = [10 13 12 11 14 15 14 15 13 10 12 15 15 15 14 13 11 11 12 12 13 10 9 8]';

% ---- 参数修改 ----
args = varargin;
if ~isempty(args) && ischar(args{1}) && strcmp(args{1}, 'literal')
    p.sell_factor = 1;
    p.om_basis = 'energy';
    args = args(2:end);
end
if mod(numel(args), 2) ~= 0
    error('参数须成对给出：ies_params(''名称'', 值, ...)');
end
for k = 1:2:numel(args)
    if ~isfield(p, args{k})
        error('未知参数：%s', args{k});
    end
    p.(args{k}) = args{k + 1};
end
end

function p = ies_params_with(p, caps)
% IES_PARAMS_WITH  用结构体 caps 中的字段覆盖参数 p（例如 PSO 得到的最优容量）
names = fieldnames(caps);
for k = 1:numel(names)
    p.(names{k}) = caps.(names{k});
end
end

%% ---------------------------------------------------------------------
%  模型：变量、约束（设备 / 爬坡 / CCS / 储能 / 能量平衡 / 阶梯碳交易）、目标函数、求解
%  ---------------------------------------------------------------------
function res = ies_solve(p, mode, solver)
% IES_SOLVE  第 4 节：24 h 优化调度（MILP，YALMIP 建模）
%
%   res = ies_solve()                       默认参数、储能 'paper' 口径、YALMIP 自动选求解器
%   res = ies_solve(p, mode, solver)
%     p      : ies_params() 返回的参数
%     mode   : 储能首末条件
%              'paper'      按论文作者的实现：S_n(1) = 0（第 1 时段末库存为零，库存下限从第 2
%                           时段起生效），第 1 时段仍须充电 Pcha(1) ≥ 0.2·Pmax_n，但这部分能量
%                           不进入库存，第 2 时段再充 Smin/η 达到下限。论文 Fig.4 中 0:00、1:00
%                           两个时段都在充电（储氢 200 kg、210 kg）正是这种写法的结果
%              'zero_start' 调度开始前库存为 0，第 1 时段的充电计入库存（物理上自洽）
%              'cyclic'     日内循环：S_n(T) = S_n(0)，不需要首时段充电约束
%     solver : 'gurobi' | 'cplex' | 'intlinprog' | 'glpk' | ''（YALMIP 自动选择）
%
%   返回结构体 res：ok, total, costs（COP/CCT/CEP/CWS/CCS）, summary, ts（各逐时序列，T×1）
%
% 目标函数 Eq.(12)：min C = COP + CCT + CEP + CWS + CCS
% 设备 Eq.(1)–(7)，阶梯碳交易 Eq.(8)–(11)，储能 Eq.(19)–(20)，能量平衡 Eq.(21)–(24)

if nargin < 1 || isempty(p),      p = ies_params(); end
if nargin < 2 || isempty(mode),   mode = 'paper';   end
if nargin < 3,                    solver = '';      end
if ~any(strcmp(mode, {'paper', 'zero_start', 'cyclic'}))
    error('mode 只能是 ''paper''、''zero_start'' 或 ''cyclic''');
end

T = p.T;  dt = p.dt;
yalmip('clear');
C = [];

% ---- 外购能源 ----
buy_e = sdpvar(T, 1);  buy_h = sdpvar(T, 1);  buy_g = sdpvar(T, 1);  buy_H = sdpvar(T, 1);  % buy_H: kg/h
C = [C, 0 <= buy_e, 0 <= buy_h, 0 <= buy_g, 0 <= buy_H];
if ~isinf(p.buy_max_e), C = [C, buy_e <= p.buy_max_e]; end
if ~isinf(p.buy_max_h), C = [C, buy_h <= p.buy_max_h]; end
if ~isinf(p.buy_max_g), C = [C, buy_g <= p.buy_max_g]; end
if ~isinf(p.buy_max_H), C = [C, buy_H <= p.buy_max_H]; end

% ---- 风光实际出力 Eq.(18)，弃电量 = 可用 − 实际 ----
wt = sdpvar(T, 1);  pv = sdpvar(T, 1);
C = [C, 0 <= wt <= p.WT_avail, 0 <= pv <= p.PV_avail];
wt_cut = p.WT_avail - wt;
pv_cut = p.PV_avail - pv;

% ---- GT Eq.(1)、WHB Eq.(3) ----
gt_e = sdpvar(T, 1);
gt_g = gt_e / p.eta_GT;
gt_h = gt_e * (1 - p.eta_GT - p.eta_loss) / p.eta_GT;
whb_h = p.eta_WHB * gt_h;
C = [C, 0 <= gt_e <= p.PGT_max, whb_h <= p.PWHB_max];

% ---- GB Eq.(2) ----
gb_h = sdpvar(T, 1);
gb_g = gb_h / p.eta_GB;
C = [C, 0 <= gb_h <= p.PGB_max];

% ---- EL Eq.(4) ----
el_e = sdpvar(T, 1);
el_H = p.eta_EL * el_e / p.meh;
C = [C, 0 <= el_e <= p.PEL_max];

% ---- MR Eq.(5) ----
mr_H = sdpvar(T, 1);
mr_g = p.eta_MR * mr_H * p.meh;
C = [C, 0 <= mr_H <= p.HMR_max];

% ---- HFC Eq.(6) ----
hfc_H = sdpvar(T, 1);
hfc_P = p.eta_HFC * hfc_H * p.meh;
hfc_e = p.eta_HFC_e * hfc_P;
hfc_h = p.eta_HFC_h * hfc_P;
C = [C, 0 <= hfc_H <= p.HHFC_max];

% ---- 爬坡约束：|x(t+1) − x(t)| ≤ ramp · 额定容量 ----
C = [C, -p.ramp_GT  * p.PGT_max  <= diff(gt_e)  <= p.ramp_GT  * p.PGT_max];
C = [C, -p.ramp_GB  * p.PGB_max  <= diff(gb_h)  <= p.ramp_GB  * p.PGB_max];
C = [C, -p.ramp_EL  * p.PEL_max  <= diff(el_e)  <= p.ramp_EL  * p.PEL_max];
C = [C, -p.ramp_MR  * p.HMR_max  <= diff(mr_H)  <= p.ramp_MR  * p.HMR_max];
C = [C, -p.ramp_HFC * p.HHFC_max <= diff(hfc_H) <= p.ramp_HFC * p.HHFC_max];

% ---- CCS Eq.(7) 与实际碳排放 Eq.(9) ----
co2_gt = p.k_GT_e * gt_e + p.k_GT_h * gt_h;
co2_gb = p.k_GB_a * gb_h;
co2 = co2_gt + co2_gb;                 % GT+GB 产生的 CO2
co2_cap = p.eta_CCS * co2;             % 捕集量
co2_uncap = (1 - p.eta_CCS) * co2;     % 未捕集量
ccs_e = p.e_ccs * co2_cap;             % CCS 耗电
co2_mr = p.theta * mr_H;               % MR 利用的 CO2
co2_cs = co2_cap - co2_mr;             % 封存量
C = [C, co2_mr <= co2_cap];            % 0 ≤ E_MR ≤ E_cap

% ---- 储能 Eq.(19)–(20) ----
nS = numel(p.ES.p_max);
cap = repmat(p.ES.p_max, T, 1);        % Pmax_n(t)
for n = 1:nS
    if p.ES.degrade(n)                 % 电储能容量衰减 Eq.(19)
        tt = (1:T)';
        cap(:, n) = p.deg(1) + p.deg(2) * tt - p.deg(3) * tt.^2 - p.deg(4) * sqrt(tt);
    end
end
cha = sdpvar(T, nS, 'full');  dis = sdpvar(T, nS, 'full');  soc = sdpvar(T, nS, 'full');
b_cha = binvar(T, nS, 'full');  b_dis = binvar(T, nS, 'full');
soc0 = sdpvar(1, nS);                  % 调度开始前的库存 S_n(0)
C = [C, 0 <= cha <= 0.3 * cap .* b_cha, 0 <= dis <= 0.3 * cap .* b_dis, b_cha + b_dis <= 1];
for n = 1:nS
    mu = p.ES.mu(n);  ec = p.ES.eta_cha(n);  ed = p.ES.eta_dis(n);
    dyn = soc(2:T, n) == (1 - mu) * soc(1:T-1, n) + ec * cha(2:T, n) - dis(2:T, n) / ed;
    switch mode
        case 'paper'
            C = [C, soc(1, n) == 0, dyn, ...
                 0.2 * cap(2:T, n) <= soc(2:T, n) <= 0.9 * cap(2:T, n), ...
                 cha(1, n) >= 0.2 * cap(1, n)];
        case 'zero_start'
            C = [C, soc(1, n) == ec * cha(1, n) - dis(1, n) / ed, dyn, ...
                 0.2 * cap(:, n) <= soc(:, n) <= 0.9 * cap(:, n), ...
                 cha(1, n) >= 0.2 * cap(1, n)];
        case 'cyclic'
            C = [C, soc(1, n) == (1 - mu) * soc0(n) + ec * cha(1, n) - dis(1, n) / ed, dyn, ...
                 0.2 * cap(:, n) <= soc(:, n) <= 0.9 * cap(:, n), ...
                 0.2 * cap(1, n) <= soc0(n) <= 0.9 * cap(1, n), soc(T, n) == soc0(n)];
    end
end

% ---- 能量平衡 Eq.(21)–(24) ----
C = [C, buy_e + gt_e + hfc_e + dis(:, 1) + wt + pv == p.load_e + el_e + cha(:, 1) + ccs_e];
C = [C, buy_h + whb_h + hfc_h + dis(:, 2) + gb_h == p.load_h + cha(:, 2)];
C = [C, buy_g + mr_g + dis(:, 3) == p.load_g + cha(:, 3) + gt_g + gb_g];
C = [C, buy_H + el_H + dis(:, 4) == mr_H + hfc_H + p.load_H + cha(:, 4)];

% ---- 阶梯碳交易 Eq.(8)、(10)、(11) ----
quota = p.k_buy * buy_e + p.k_GT * gt_g + p.k_GB * gb_g;   % 初始碳配额
co2_env = co2_uncap + p.k_buy_a * buy_e;                   % 排入环境的 CO2
E_a = sum(co2_env - quota);                                % 参与交易的净排放
% 净排放拆成买入量与卖出量，用二进制变量保证二者不同时为正。
% 买入成本是分段线性凸函数，等于 5 条直线的最大值：
%   第 k 段：λ(1+kα)(E − k·l) + λ·l·(k + α·k(k−1)/2)，k = 0..4
% 与 Eq.(11) 各段截距 λl, λl(2+α), λl(3+3α), λl(4+6α) 一致；最小化时 c_buy 自动取到 f(E_buy)。
E_buy = sdpvar(1);  E_sell = sdpvar(1);  y_buy = binvar(1);  c_buy = sdpvar(1);
M = 1e5;
C = [C, E_a == E_buy - E_sell, 0 <= E_buy <= M * y_buy, 0 <= E_sell <= M * (1 - y_buy), c_buy >= 0];
for k = 0:4
    slope = p.lam * (1 + k * p.alpha_step);
    icpt = p.lam * p.l_step * (k + p.alpha_step * k * (k - 1) / 2);
    C = [C, c_buy >= slope * (E_buy - k * p.l_step) + icpt];
end
CCT = c_buy - p.sell_factor * p.lam * E_sell;

% ---- 目标函数 Eq.(12)–(17) ----
if strcmp(p.om_basis, 'capacity')
    om_conv = p.a_GT * p.PGT_max + p.a_GB * p.PGB_max + p.a_WHB * p.PWHB_max ...
            + p.a_EL * p.PEL_max + p.a_MR * p.HMR_max + p.a_HFC * p.HHFC_max;
elseif strcmp(p.om_basis, 'energy')
    om_conv = dt * sum(p.a_GT * gt_e + p.a_GB * gb_h + p.a_WHB * whb_h ...
                       + p.a_EL * el_e + p.a_MR * mr_g + p.a_HFC * hfc_P);
else
    error('om_basis 只能是 ''capacity'' 或 ''energy''');
end
om_other = dt * (sum(p.a_CCS * ccs_e + p.a_WT * wt + p.a_PV * pv) ...
                 + sum((cha + dis) * p.ES.alpha'));
COP = om_conv + om_other;
CEP = dt * sum(p.price_elec .* buy_e + p.price_heat * buy_h + p.price_gas * buy_g ...
               + p.price_H2 * p.meh * buy_H);
CWS = dt * sum(p.pen_WT * wt_cut + p.pen_PV * pv_cut);
CCS = sum(p.k_cs * co2_cs);
obj = COP + CCT + CEP + CWS + CCS;

% ---- 求解 ----
% 注意：不要用 sdpsettings 设置 gurobi.* 参数。只要改动其中任何一项，YALMIP 就会把整套
% 默认参数一起传给 Gurobi，其中 TuneTimeLimit = -1 会被新版 Gurobi 拒绝（error 10008）。
ops = sdpsettings('verbose', 0);
if ~isempty(solver)
    ops = sdpsettings(ops, 'solver', solver);
end
sol = optimize(C, obj, ops);

res.p = p;
res.mode = mode;
res.ok = sol.problem == 0;
res.info = sol.info;
if ~res.ok
    res.total = NaN;
    return
end

v = @(x) double(value(x));
res.total = v(obj);
res.costs = struct('COP', v(COP), 'CCT', v(CCT), 'CEP', v(CEP), 'CWS', v(CWS), 'CCS', v(CCS));

ts.t = (0:T-1)';
% 电
ts.E_Load = p.load_e;  ts.E_Buy = v(buy_e);  ts.WT = v(wt);  ts.PV = v(pv);
ts.GT_e = v(gt_e);  ts.HFC_e = v(hfc_e);  ts.EL_e = v(el_e);  ts.CCS_e = v(ccs_e);
ts.WT_cut = v(wt_cut);  ts.PV_cut = v(pv_cut);
% 热
ts.H_Load = p.load_h;  ts.H_Buy = v(buy_h);  ts.WHB_h = v(whb_h);  ts.GB_h = v(gb_h);  ts.HFC_h = v(hfc_h);
% 气
ts.G_Load = p.load_g;  ts.G_Buy = v(buy_g);  ts.MR_g = v(mr_g);  ts.GT_g = v(gt_g);  ts.GB_g = v(gb_g);
% 氢
ts.H2_Load = p.load_H;  ts.H2_Buy = v(buy_H);  ts.EL_H2 = v(el_H);  ts.HFC_H2 = v(hfc_H);  ts.MR_H2 = v(mr_H);
% 储能（列 1–4：电、热、气、氢）
ts.ES_cha = v(cha);  ts.ES_dis = v(dis);  ts.SOC = v(soc);
% 碳
ts.CO2_GT = v(co2_gt);  ts.CO2_GB = v(co2_gb);  ts.CO2_cap = v(co2_cap);  ts.CO2_uncap = v(co2_uncap);
ts.CO2_MR = v(co2_mr);  ts.CO2_CS = v(co2_cs);  ts.CO2_env = v(co2_env);
res.ts = ts;

s.CO2_gen = sum(ts.CO2_GT + ts.CO2_GB);          % CO2 产生量 / t
s.CO2_emit = sum(ts.CO2_uncap);                  % CO2 排放量 / t
s.CCS_elec = sum(ts.CCS_e);                      % CCS 耗电 / MWh
s.E_trade = v(E_a);                              % 参与交易的净排放 / t
s.curtail = sum(ts.WT_cut + ts.PV_cut);          % 弃风弃光 / MWh
s.dS = ts.SOC(1, :) - ts.SOC(T, :);              % ΔS_n = S_n(1) − S_n(T)
res.summary = s;
end

%% ---------------------------------------------------------------------
%  结果输出
%  ---------------------------------------------------------------------
function ies_report(res)
% IES_REPORT  打印调度结果，并与论文第 4 节报告值逐项对比

c = res.costs;  s = res.summary;
z = @(x) x .* (abs(x) > 1e-6) + 0;   % 去掉求解器残留的 -0.00
fprintf('调度总成本 / ¥: %s\n', fmt(res.total));
fprintf('  外购能源成本 CEP / ¥: %s\n', fmt(c.CEP));
fprintf('  运维成本 COP / ¥: %s\n', fmt(c.COP));
fprintf('  阶梯碳交易成本 CCT / ¥: %s\n', fmt(c.CCT));
fprintf('  弃风弃光惩罚 CWS / ¥: %s\n', fmt(z(c.CWS)));
fprintf('  碳封存成本 CCS / ¥: %s\n', fmt(c.CCS));
fprintf('  参与交易净排放 / t: %.2f\n', s.E_trade);
fprintf('  弃风弃光 / MWh: %.2f\n', z(s.curtail));
names = res.p.ES.name;
for n = 1:numel(names)
    fprintf('  ΔS%d %s S(1)−S(T): %.2f\n', n, names{n}, z(s.dS(n)));
end

% 论文第 4 节报告的基准调度结果
label = {'总成本', '外购能源成本 CEP', '运维成本 COP', '碳交易成本 CCT', '弃风弃光成本 CWS', ...
         '碳封存成本 CCS', 'CO2 产生量 / t', 'CO2 排放量 / t', 'CCS 耗电 / MWh'};
paper = [847510.4, 907654.7, 271766.2, -341820.2, 9558.5, 351.1, 386.8273, 135.3896, 67.0];
ours = [res.total, c.CEP, c.COP, c.CCT, z(c.CWS), c.CCS, s.CO2_gen, s.CO2_emit, s.CCS_elec];
fprintf('\n与论文第 4 节结果对比：\n');
fprintf('%-18s %14s %14s %10s\n', '指标', '本模型', '论文', '偏差 %');
for k = 1:numel(label)
    fprintf('%-18s %14s %14s %10.2f\n', label{k}, fmt(ours(k)), fmt(paper(k)), ...
            (ours(k) - paper(k)) / abs(paper(k)) * 100);
end
end

function s = fmt(x)
% 千分位格式，保留 1 位小数
neg = x < 0;
s = sprintf('%.1f', abs(x));
dot = strfind(s, '.');
intpart = s(1:dot-1);
n = numel(intpart);
for k = n-3:-3:1
    intpart = [intpart(1:k), ',', intpart(k+1:end)];
end
s = [intpart, s(dot:end)];
if neg, s = ['-', s]; end
end

%% ---------------------------------------------------------------------
%  画图
%  ---------------------------------------------------------------------
function ies_plot(res, outdir)
% IES_PLOT  电/热/气/氢平衡与碳捕集/封存共 6 张图（对应论文 Fig.4(a)–(f)）
%
%   ies_plot(res)            在屏幕上显示
%   ies_plot(res, 'pic')     同时把 PNG 保存到 pic/ 目录

if nargin < 2, outdir = ''; end
if ~isempty(outdir) && ~exist(outdir, 'dir'), mkdir(outdir); end
ts = res.ts;
f = @(name) fullfile_or_empty(outdir, name);

balance_fig(ts.t, ...
    {'外部购电', '风机出力', '光伏出力', '燃气轮机', '氢燃料电池', '蓄电池放电'}, ...
    [ts.E_Buy, ts.WT, ts.PV, ts.GT_e, ts.HFC_e, ts.ES_dis(:, 1)], ...
    {'电解槽耗电', '蓄电池充电', '碳捕集耗电'}, [ts.EL_e, ts.ES_cha(:, 1), ts.CCS_e], ...
    ts.E_Load, '电负荷能量平衡图', 'Power/MW', f('elec_balance.png'));
balance_fig(ts.t, ...
    {'外部购热', '余热锅炉', '燃气锅炉', '氢燃料电池热', '蓄热放热'}, ...
    [ts.H_Buy, ts.WHB_h, ts.GB_h, ts.HFC_h, ts.ES_dis(:, 2)], ...
    {'蓄热储热'}, ts.ES_cha(:, 2), ...
    ts.H_Load, '热负荷能量平衡图', 'Power/MW', f('heat_balance.png'));
balance_fig(ts.t, ...
    {'外部购气', '甲烷发生器', '储气放气'}, [ts.G_Buy, ts.MR_g, ts.ES_dis(:, 3)], ...
    {'储气充气', '燃气轮机耗气', '燃气锅炉耗气'}, [ts.ES_cha(:, 3), ts.GT_g, ts.GB_g], ...
    ts.G_Load, '天然气平衡分析图', 'Power/MW', f('gas_balance.png'));
balance_fig(ts.t, ...
    {'外部购氢', '电解槽制氢', '储氢放氢'}, [ts.H2_Buy, ts.EL_H2, ts.ES_dis(:, 4)], ...
    {'储氢充氢', '燃料电池耗氢', '甲烷发生器耗氢'}, [ts.ES_cha(:, 4), ts.HFC_H2, ts.MR_H2], ...
    ts.H2_Load, '氢能平衡分析图', 'Mass/kg', f('hydrogen_balance.png'));
balance_fig(ts.t, {'CCS', 'Non-CCS'}, [ts.CO2_cap, ts.CO2_uncap], ...
    {'GT', 'GB'}, [ts.CO2_GT, ts.CO2_GB], ...
    [], 'Carbon Capture Status', 'Mass/t', f('carbon_cap.png'));
balance_fig(ts.t, {'Carbon Capture'}, ts.CO2_cap, ...
    {'Carbon Storage', 'MR'}, [ts.CO2_CS, ts.CO2_MR], ...
    [], 'Carbon Storage Status', 'Mass/t', f('carbon_storage.png'));
end

function fpath = fullfile_or_empty(outdir, name)
if isempty(outdir), fpath = ''; else, fpath = fullfile(outdir, name); end
end

function balance_fig(t, posNames, posVals, negNames, negVals, load, ttl, ylab, fpath)
fig = figure('Color', 'w', 'Position', [100, 100, 609, 521]);
hold on;
hp = bar(t, posVals, 0.8, 'stacked');
hn = bar(t, -negVals, 0.8, 'stacked');
paint(hp, posNames);
paint(hn, negNames);
handles = [hp(:); hn(:)];
labels = [posNames, negNames];
if ~isempty(load)
    hl = plot(t, load, '-o', 'Color', [0.93, 0.11, 0.14], 'LineWidth', 1.5, 'MarkerSize', 4);
    handles = [handles; hl];
    labels = [labels, {'负荷需求'}];
end
plot([t(1) - 1, t(end) + 1], [0, 0], 'k-', 'LineWidth', 0.8, 'HandleVisibility', 'off');
xlim([t(1) - 1, t(end) + 1]);
title(ttl, 'FontWeight', 'bold');
xlabel('Time/hour');
ylabel(ylab);
box on;
set(gca, 'TickDir', 'in');
try
    legend(handles, labels, 'Location', 'southoutside', 'NumColumns', 3);
catch   % Octave 不支持 NumColumns
    legend(handles, labels, 'Location', 'eastoutside');
end
hold off;
if ~isempty(fpath)
    print(fig, fpath, '-dpng', '-r150');
end
end

function paint(h, names)
for i = 1:numel(h)
    set(h(i), 'FaceColor', color_of(names{i}), 'EdgeColor', 'k', 'LineWidth', 0.5);
end
end

function c = color_of(name)
persistent cmap
if isempty(cmap)
    keys = {'外部购电', '外部购气', '外部购氢', '外部购热', '风机出力', '光伏出力', ...
            '燃气轮机', '燃气锅炉', '甲烷发生器', '余热锅炉', '电解槽制氢', '碳捕集耗电', ...
            '氢燃料电池', '氢燃料电池热', '蓄电池放电', '蓄热放热', '储气放气', '储氢放氢', ...
            '蓄电池充电', '蓄热储热', '储气充气', '储氢充氢', '电解槽耗电', '燃气轮机耗气', ...
            '燃气锅炉耗气', '燃料电池耗氢', '甲烷发生器耗氢', 'CCS', 'Non-CCS', 'GT', 'GB', ...
            'Carbon Capture', 'Carbon Storage', 'MR'};
    hex = {'00AEEF', '00AEEF', '00AEEF', '00AEEF', 'FFC000', '0A562C', ...
           'ED1C24', 'ED1C24', 'F4B183', '00B050', '00B050', '92D050', ...
           '99CCFF', '99CCFF', '7F7F7F', '7F7F7F', '7F7F7F', '7F7F7F', ...
           'FF3399', 'FF3399', 'FF3399', 'FF3399', '7030A0', '0700CD', ...
           '7030A0', '7030A0', 'C55A11', '3399FF', 'C55A11', '33CC33', 'FF1F1F', ...
           '3399FF', '33CC33', 'FF1F1F'};
    cmap = containers.Map(keys, hex);
end
if isKey(cmap, name), h = cmap(name); else, h = 'A6A6A6'; end
c = [hex2dec(h(1:2)), hex2dec(h(3:4)), hex2dec(h(5:6))] / 255;
end

%% ---------------------------------------------------------------------
%  第 5 节：容量配置
%  ---------------------------------------------------------------------
function cost = ies_capacity_cost(caps, p, mode, solver)
% IES_CAPACITY_COST  给定设备容量下最优调度的总成本（第 5 节的适应度函数）
%
%   cost = ies_capacity_cost(struct('PEL_max', 60.6), p, mode, solver)
%   caps 的字段名为 PGT_max / PEL_max / HMR_max / HHFC_max / PGB_max / PWHB_max，
%   求解失败时返回 Inf。

if nargin < 2 || isempty(p),    p = ies_params(); end
if nargin < 3 || isempty(mode), mode = 'paper';   end
if nargin < 4,                  solver = '';      end
res = ies_solve(ies_params_with(p, caps), mode, solver);
if res.ok, cost = res.total; else, cost = Inf; end
end

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
fitness = @(xi) ies_capacity_cost(cell2struct(num2cell(xi), names, 2), p, mode, solver);
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
end
