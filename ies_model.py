"""
电–热–气–氢综合能源系统（IES）优化调度与容量配置模型 —— 论文复现

Wang J, Liu H, Xu C. Resource scheduling and capacity allocation optimization of an
integrated electricity-heat-gas-hydrogen energy system. Energy, 2025, 337: 138683.
https://doi.org/10.1016/j.energy.2025.138683

第 4 节：24 h 优化调度，混合整数线性规划（MILP）
    min C = COP + CCT + CEP + CWS + CCS                                   Eq.(12)
    设备 Eq.(1)–(7)，阶梯碳交易 Eq.(8)–(11)，储能 Eq.(19)–(20)，四能量平衡 Eq.(21)–(24)
第 5 节：设备容量与最优调度成本的关系，单设备容量寻优与多设备 PSO 容量寻优

默认参数复现论文报告的结果。与论文公式字面写法不同的三处（依据见 README）：
    1. 储能首末条件按作者实际实现（S_n(1) = 0，见 build_model 的 mode 说明）
    2. 富余碳配额按 2λ 出售（sell_factor = 2）
    3. GT/GB/WHB/EL/MR/HFC 的运维成本按 α_i × 额定容量计（om_basis = "capacity"）
Params.literal() 给出完全按论文公式字面实现的参数。

用法：
    python ies_model.py                  # 第 4 节基准调度，并与论文结果对比
    python ies_model.py --plot pic       # 同上，并把 6 张结果图保存到 pic/
    python ies_model.py --section5       # 第 5 节：论文各优化容量下的成本变化
    python ies_model.py --literal        # 按论文公式字面实现求解
    python ies_model.py --mode cyclic    # 储能改为日内循环口径
"""

import argparse
import math
import os
from dataclasses import dataclass, field, replace
from typing import Dict, List, Optional, Sequence

import gurobipy as grb
from gurobipy import GRB
import numpy as np
import pandas as pd

T = 24      # 调度时段数
DT = 1.0    # 时段长度（h）
STORAGE_MODES = ("paper", "zero_start", "cyclic")


# =========================
# 1) 参数（论文 Table 1–3、Fig.2–3）
# =========================
@dataclass
class Storage:
    """第 n 类储能。论文 Eq.(20) 中所有限值都按 Pmax_n 的比例给出：
        充/放功率上限 0.3·Pmax_n，库存上下限 0.2·Pmax_n ~ 0.9·Pmax_n，首时段充电 ≥ 0.2·Pmax_n
    Table 2 的数值正是这些比例的结果（例如电储能 Pmax_1 = 200：60 MW、40/180 MWh），
    所以这里只存 Pmax_n，避免把 0.3 重复乘两次。"""
    name: str
    p_max: float        # Pmax_n：储能额定容量（MWh 或 kg）
    eta_cha: float      # 充电效率
    eta_dis: float      # 放电效率
    mu: float           # 自放电率
    alpha: float        # 运维成本（¥/MWh 或 ¥/kg），按充放电量计
    degrade: bool = False   # 是否按 Eq.(19) 考虑容量衰减（仅电储能）


@dataclass
class Params:
    # ---- 燃气轮机 GT ----
    PGT_max: float = 580.0      # MW
    ramp_GT: float = 0.2        # 爬坡率（额定容量的比例）
    eta_GT: float = 0.35
    eta_loss: float = 0.1
    a_GT: float = 12.5          # 运维成本系数
    # ---- 燃气锅炉 GB ----
    PGB_max: float = 1000.0     # MW
    ramp_GB: float = 0.2
    eta_GB: float = 0.75
    a_GB: float = 85.0
    # ---- 余热锅炉 WHB ----
    PWHB_max: float = 600.0     # MW
    eta_WHB: float = 0.75
    a_WHB: float = 65.0
    # ---- 电解槽 EL ----
    PEL_max: float = 5.0        # MW
    ramp_EL: float = 0.2
    eta_EL: float = 0.75
    a_EL: float = 25.0
    meh: float = 0.03954        # 氢气热值（MWh/kg）
    # ---- 甲烷发生器 MR ----
    HMR_max: float = 1000.0     # kg/h
    ramp_MR: float = 0.2
    eta_MR: float = 0.6
    a_MR: float = 19.0
    theta: float = 0.00135      # MR 的 CO2 利用系数（t/kg）
    # ---- 氢燃料电池 HFC ----
    HHFC_max: float = 25.0      # kg/h
    ramp_HFC: float = 0.2
    eta_HFC: float = 0.95
    eta_HFC_e: float = 0.8
    eta_HFC_h: float = 0.15
    a_HFC: float = 18.0
    # ---- 碳捕集 CCS ----
    eta_CCS: float = 0.65
    e_ccs: float = 0.269        # MWh/t
    k_cs: float = 1.4           # ¥/t
    a_CCS: float = 55.0         # ¥/MWh，按 CCS 耗电量计
    # ---- 风电 / 光伏 ----
    a_WT: float = 70.0          # ¥/MWh，按实际出力计
    a_PV: float = 32.0
    pen_WT: float = 200.0       # 弃风惩罚 ¥/MWh
    pen_PV: float = 200.0       # 弃光惩罚 ¥/MWh
    # ---- 碳配额系数（kg/kWh = t/MWh）----
    k_buy: float = 0.68
    k_GT: float = 0.612
    k_GB: float = 0.306
    # ---- 实际碳排放系数（kg/kWh = t/MWh）----
    k_buy_a: float = 1.08
    k_GT_e: float = 0.195
    k_GT_h: float = 0.39
    k_GB_a: float = 0.195
    # ---- 阶梯碳交易 ----
    lam: float = 250.0          # 基准碳价 ¥/t
    l_step: float = 100.0       # 区间长度 t
    alpha_step: float = 0.25    # 价格增长率
    # 富余配额出售价 = sell_factor·λ。Eq.(11) 字面为 1；论文报告的碳交易收益在第 4、5 节
    # 都恰好等于 2λ × 富余配额，取 2 才能复现论文结果。
    sell_factor: float = 2.0
    # GT/GB/WHB/EL/MR/HFC 的运维成本口径：
    #   "capacity"：α_i × 额定容量（论文符号表中 α_i 单位为 ¥/MW；Table 4 中缩小容量带来的
    #               成本下降恰好等于 α_i × 容量减少量，第 5 节的容量寻优也依赖这一项）
    #   "energy"  ：Σ_t α_i × P_i,t（Eq.(13) 字面写法）
    om_basis: str = "capacity"
    # ---- 能源价格 ----
    price_gas: float = 350.0    # ¥/MWh
    price_H2: float = 1500.0    # ¥/MWh（按热值折算）
    price_heat: float = 1000.0  # ¥/MWh
    price_elec: List[float] = field(default_factory=lambda: (
        [343.8] * 7 + [680.0] * 4 + [811.0] * 3 + [680.0] * 3 + [811.0] * 5 + [380.0] * 2))  # Table 3
    # ---- 外购上限（论文未给出数值，默认不限）----
    buy_max_e: Optional[float] = None
    buy_max_h: Optional[float] = None
    buy_max_g: Optional[float] = None
    buy_max_H: Optional[float] = None
    # ---- 储能（Table 2，Eq.(19)–(20)）----
    storages: List[Storage] = field(default_factory=lambda: [
        Storage("电储能", 200.0, 0.95, 0.95, 0.001, 18.0, degrade=True),
        Storage("热储能", 200.0, 0.95, 0.95, 0.0, 16.0),
        Storage("气储能", 100.0, 0.95, 0.95, 0.0, 16.0),
        Storage("氢储能", 1000.0, 0.95, 0.95, 0.0, 16.0),
    ])
    deg: tuple = (200.0, 4.168e-4, 1.9984e-7, 0.0332)   # Eq.(19) 的 a, b, c, d
    # ---- 风光出力（读自 Fig.2）与负荷（读自 Fig.3）----
    WT_avail: List[float] = field(default_factory=lambda: [
        20, 33, 36, 46, 47, 43, 40, 50, 38, 34, 48, 31, 38, 29, 11, 8, 32, 47, 33, 42, 52, 50, 59, 42.5])
    PV_avail: List[float] = field(default_factory=lambda: [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 17, 30, 40, 45, 46, 43, 33, 21, 8, 0, 0, 0, 0, 0, 0])
    load_e: List[float] = field(default_factory=lambda: [
        15, 25, 26, 28, 28, 32, 35, 41, 43, 49, 55, 68, 66, 56, 43, 42, 47, 51, 53, 54, 50, 39, 30, 27])
    load_h: List[float] = field(default_factory=lambda: [
        45, 24, 38, 48, 51, 58, 43, 58, 68, 83, 80, 84, 70, 68, 65, 62, 65, 88, 50, 48, 45, 55, 63, 50])
    load_H: List[float] = field(default_factory=lambda: [   # kg/h
        80, 66, 60, 50, 50, 55, 55, 100, 152, 136, 80, 70, 70, 70, 90, 90, 80, 70, 70, 70, 70, 70, 70, 70])
    load_g: List[float] = field(default_factory=lambda: [
        10, 13, 12, 11, 14, 15, 14, 15, 13, 10, 12, 15, 15, 15, 14, 13, 11, 11, 12, 12, 13, 10, 9, 8])

    @classmethod
    def literal(cls, **kw) -> "Params":
        """完全按论文公式字面实现：富余配额按 λ 出售，运维成本全部按出力计。"""
        return cls(sell_factor=1.0, om_basis="energy", **kw)

    def storage_capacity(self, n: int) -> List[float]:
        """第 n 类储能各时段的 Pmax_n(t)。电储能按 Eq.(19) 随时间衰减，其余为常数。"""
        s = self.storages[n]
        if not s.degrade:
            return [s.p_max] * T
        a, b, c, d = self.deg
        return [a + b * t - c * t ** 2 - d * math.sqrt(t) for t in range(1, T + 1)]


# 论文第 4 节报告的基准调度结果
PAPER_RESULTS = {
    "总成本": 847510.4,
    "外购能源成本 CEP": 907654.7,
    "运维成本 COP": 271766.2,
    "碳交易成本 CCT": -341820.2,
    "弃风弃光成本 CWS": 9558.5,
    "碳封存成本 CCS": 351.1,
    "CO2 产生量 / t": 386.8273,
    "CO2 排放量 / t": 135.3896,
    "CCS 耗电 / MWh": 67.0,
}

# 第 5 节容量相关的设备与参数名
CAPACITY_KEYS = {"GT": "PGT_max", "EL": "PEL_max", "MR": "HMR_max",
                 "HFC": "HHFC_max", "GB": "PGB_max", "WHB": "PWHB_max"}

# 论文 Table 4：单设备容量寻优（PSO）的最优容量与总成本
PAPER_TABLE4 = {"GT": (254.1259, 843440.0), "EL": (60.6105, 570690.0), "MR": (72.7329, 830750.0),
                "HFC": (0.0, 847060.0), "GB": (81.7263, 770170.0), "WHB": (81.2426, 813800.0)}

# 论文 Table 6：六设备容量同时寻优（PSO）的结果
PAPER_OPT_CAPACITY = {"PGT_max": 162.8317, "PEL_max": 65.5134, "HMR_max": 1127.2,
                      "HHFC_max": 0.0, "PGB_max": 0.0, "PWHB_max": 87.9743}
PAPER_OPT_COST = 446106.7


# =========================
# 2) 建模
# =========================
_ENV = None


def _env():
    """共用一个静默的 Gurobi 环境，避免容量寻优时反复打印许可证信息。"""
    global _ENV
    if _ENV is None:
        _ENV = grb.Env(empty=True)
        _ENV.setParam("OutputFlag", 0)
        _ENV.start()
    return _ENV


def build_model(p: Params, mode: str = "paper", verbose: bool = False):
    """建立调度模型，返回 (model, 决策变量 dict, 导出量 dict)。

    储能首末条件（mode）：
    "paper"      ：按论文作者的实现复现。S_n(1) = 0（第 1 时段末库存为零，库存下限从第 2 时段起生效），
                   第 1 时段仍须充电 Pcha(1) ≥ 0.2·Pmax_n，但这部分能量不进入库存；
                   第 2 时段再充 Smin/η 达到下限。论文 Fig.4 中 0:00、1:00 两个时段都在充电
                   （例如储氢 200 kg、210 kg，储气 20、21 MW）正是这种写法的结果。
                   ΔS_n = S_n(1) − S_n(T) 只是首末差值，不另加约束。
    "zero_start" ：物理上自洽的写法。调度开始前库存 S_n(0) = 0，第 1 时段的充电计入库存。
    "cyclic"     ：日内循环。S_n(0) 为决策变量，要求 S_n(T) = S_n(0)，不需要首时段充电约束。
    """
    if mode not in STORAGE_MODES:
        raise ValueError(f"mode 只能是 {STORAGE_MODES}")
    if p.om_basis not in ("capacity", "energy"):
        raise ValueError("om_basis 只能是 'capacity' 或 'energy'")

    m = grb.Model("IES_E_H_G_H2", env=_env())
    m.Params.OutputFlag = 1 if verbose else 0
    m.Params.MIPGap = 1e-6
    R = range(T)
    inf = GRB.INFINITY

    def ub(x):
        return inf if x is None else x

    v = {}  # 决策变量
    e = {}  # 由决策变量线性导出的量（便于取结果）

    # ---- 外购能源 ----
    v["buy_e"] = m.addVars(T, ub=ub(p.buy_max_e), name="buy_e")   # MW
    v["buy_h"] = m.addVars(T, ub=ub(p.buy_max_h), name="buy_h")   # MW
    v["buy_g"] = m.addVars(T, ub=ub(p.buy_max_g), name="buy_g")   # MW
    v["buy_H"] = m.addVars(T, ub=ub(p.buy_max_H), name="buy_H")   # kg/h

    # ---- 风光实际出力 Eq.(18)，弃电量 = 可用 − 实际 ----
    v["wt"] = m.addVars(T, ub=p.WT_avail, name="wt")
    v["pv"] = m.addVars(T, ub=p.PV_avail, name="pv")
    e["wt_cut"] = [p.WT_avail[t] - v["wt"][t] for t in R]
    e["pv_cut"] = [p.PV_avail[t] - v["pv"][t] for t in R]

    # ---- GT Eq.(1)、WHB Eq.(3) ----
    v["gt_e"] = m.addVars(T, ub=p.PGT_max, name="gt_e")
    e["gt_g"] = [v["gt_e"][t] / p.eta_GT for t in R]
    e["gt_h"] = [v["gt_e"][t] * (1 - p.eta_GT - p.eta_loss) / p.eta_GT for t in R]
    e["whb_h"] = [p.eta_WHB * e["gt_h"][t] for t in R]
    m.addConstrs((e["whb_h"][t] <= p.PWHB_max for t in R), name="WHB_max")

    # ---- GB Eq.(2) ----
    v["gb_h"] = m.addVars(T, ub=p.PGB_max, name="gb_h")
    e["gb_g"] = [v["gb_h"][t] / p.eta_GB for t in R]

    # ---- EL Eq.(4) ----
    v["el_e"] = m.addVars(T, ub=p.PEL_max, name="el_e")
    e["el_H"] = [p.eta_EL * v["el_e"][t] / p.meh for t in R]

    # ---- MR Eq.(5) ----
    v["mr_H"] = m.addVars(T, ub=p.HMR_max, name="mr_H")
    e["mr_g"] = [p.eta_MR * v["mr_H"][t] * p.meh for t in R]

    # ---- HFC Eq.(6) ----
    v["hfc_H"] = m.addVars(T, ub=p.HHFC_max, name="hfc_H")
    e["hfc_P"] = [p.eta_HFC * v["hfc_H"][t] * p.meh for t in R]
    e["hfc_e"] = [p.eta_HFC_e * e["hfc_P"][t] for t in R]
    e["hfc_h"] = [p.eta_HFC_h * e["hfc_P"][t] for t in R]

    # ---- 爬坡约束：|x(t+1) − x(t)| ≤ ramp · 额定容量 ----
    for key, rate, cap in [("gt_e", p.ramp_GT, p.PGT_max), ("gb_h", p.ramp_GB, p.PGB_max),
                           ("el_e", p.ramp_EL, p.PEL_max), ("mr_H", p.ramp_MR, p.HMR_max),
                           ("hfc_H", p.ramp_HFC, p.HHFC_max)]:
        x = v[key]
        m.addConstrs((x[t + 1] - x[t] <= rate * cap for t in range(T - 1)), name=f"{key}_up")
        m.addConstrs((x[t + 1] - x[t] >= -rate * cap for t in range(T - 1)), name=f"{key}_dn")

    # ---- CCS Eq.(7) 与实际碳排放 Eq.(9) ----
    e["co2_gt"] = [p.k_GT_e * v["gt_e"][t] + p.k_GT_h * e["gt_h"][t] for t in R]
    e["co2_gb"] = [p.k_GB_a * v["gb_h"][t] for t in R]
    e["co2"] = [e["co2_gt"][t] + e["co2_gb"][t] for t in R]                 # GT+GB 产生的 CO2
    e["co2_cap"] = [p.eta_CCS * e["co2"][t] for t in R]                     # 捕集量
    e["co2_uncap"] = [(1 - p.eta_CCS) * e["co2"][t] for t in R]             # 未捕集量
    e["ccs_e"] = [p.e_ccs * e["co2_cap"][t] for t in R]                     # CCS 耗电
    e["co2_mr"] = [p.theta * v["mr_H"][t] for t in R]                       # MR 利用的 CO2
    e["co2_cs"] = [e["co2_cap"][t] - e["co2_mr"][t] for t in R]             # 封存量
    m.addConstrs((e["co2_mr"][t] <= e["co2_cap"][t] for t in R), name="MR_CO2")  # 0 ≤ E_MR ≤ E_cap

    # ---- 储能 Eq.(19)–(20) ----
    S = len(p.storages)
    v["cha"] = m.addVars(S, T, name="cha")
    v["dis"] = m.addVars(S, T, name="dis")
    v["b_cha"] = m.addVars(S, T, vtype=GRB.BINARY, name="b_cha")
    v["b_dis"] = m.addVars(S, T, vtype=GRB.BINARY, name="b_dis")
    v["soc"] = m.addVars(S, T, name="soc")    # soc[n, t] 为第 t+1 个时段末的库存 S_n(t+1)
    v["soc0"] = m.addVars(S, name="soc0")     # 调度开始前的库存 S_n(0)（"paper" 口径不用）
    for n, s in enumerate(p.storages):
        cap = p.storage_capacity(n)
        for t in R:
            v["soc"][n, t].LB = 0.2 * cap[t]
            v["soc"][n, t].UB = 0.9 * cap[t]
            m.addConstr(v["cha"][n, t] <= 0.3 * cap[t] * v["b_cha"][n, t], name=f"ES{n+1}_cha_{t}")
            m.addConstr(v["dis"][n, t] <= 0.3 * cap[t] * v["b_dis"][n, t], name=f"ES{n+1}_dis_{t}")
            m.addConstr(v["b_cha"][n, t] + v["b_dis"][n, t] <= 1, name=f"ES{n+1}_mutex_{t}")
            if t == 0 and mode == "paper":
                continue   # S_n(1) = 0，第 1 时段不写库存方程
            prev = v["soc0"][n] if t == 0 else v["soc"][n, t - 1]
            m.addConstr(v["soc"][n, t] == (1 - s.mu) * prev + s.eta_cha * v["cha"][n, t]
                        - v["dis"][n, t] / s.eta_dis, name=f"ES{n+1}_soc_{t}")
        if mode == "paper":
            v["soc"][n, 0].LB = v["soc"][n, 0].UB = 0.0                 # S_n(1) = 0
            v["soc0"][n].UB = 0.0
            m.addConstr(v["cha"][n, 0] >= 0.2 * cap[0], name=f"ES{n+1}_first_charge")
        elif mode == "zero_start":
            v["soc0"][n].UB = 0.0                                        # S_n(0) = 0
            m.addConstr(v["cha"][n, 0] >= 0.2 * cap[0], name=f"ES{n+1}_first_charge")
        else:
            v["soc0"][n].LB = 0.2 * cap[0]
            v["soc0"][n].UB = 0.9 * cap[0]
            m.addConstr(v["soc"][n, T - 1] == v["soc0"][n], name=f"ES{n+1}_cyclic")

    def cha(n, t):
        return v["cha"][n, t]

    def dis(n, t):
        return v["dis"][n, t]

    # ---- 能量平衡 Eq.(21)–(24) ----
    m.addConstrs((v["buy_e"][t] + v["gt_e"][t] + e["hfc_e"][t] + dis(0, t) + v["wt"][t] + v["pv"][t]
                  == p.load_e[t] + v["el_e"][t] + cha(0, t) + e["ccs_e"][t] for t in R), name="bal_e")
    m.addConstrs((v["buy_h"][t] + e["whb_h"][t] + e["hfc_h"][t] + dis(1, t) + v["gb_h"][t]
                  == p.load_h[t] + cha(1, t) for t in R), name="bal_h")
    m.addConstrs((v["buy_g"][t] + e["mr_g"][t] + dis(2, t)
                  == p.load_g[t] + cha(2, t) + e["gt_g"][t] + e["gb_g"][t] for t in R), name="bal_g")
    m.addConstrs((v["buy_H"][t] + e["el_H"][t] + dis(3, t)
                  == v["mr_H"][t] + v["hfc_H"][t] + p.load_H[t] + cha(3, t) for t in R), name="bal_H")

    # ---- 阶梯碳交易 Eq.(8)、(10)、(11) ----
    e["quota"] = [p.k_buy * v["buy_e"][t] + p.k_GT * e["gt_g"][t] + p.k_GB * e["gb_g"][t] for t in R]
    e["co2_env"] = [e["co2_uncap"][t] + p.k_buy_a * v["buy_e"][t] for t in R]   # 排入环境的 CO2
    E_a = grb.quicksum(e["co2_env"][t] - e["quota"][t] for t in R)               # 参与交易的净排放
    # 净排放拆成买入量与卖出量：E_a = E_buy − E_sell，用二进制变量保证二者不同时为正。
    # 买入成本是分段线性凸函数，等于 5 条直线的最大值：
    #   第 k 段：λ(1+kα)(E − k·l) + λ·l·(k + α·k(k−1)/2)，k = 0..4
    # 与 Eq.(11) 各段截距 λl, λl(2+α), λl(3+3α), λl(4+6α) 一致；最小化时 C_buy 自动取到 f(E_buy)。
    # 卖出收益 = sell_factor·λ·E_sell。
    v["E_buy"] = m.addVar(name="E_buy")
    v["E_sell"] = m.addVar(name="E_sell")
    v["y_buy"] = m.addVar(vtype=GRB.BINARY, name="y_buy")
    M_big = 1e5
    m.addConstr(E_a == v["E_buy"] - v["E_sell"], name="CCT_split")
    m.addConstr(v["E_buy"] <= M_big * v["y_buy"], name="CCT_buy_on")
    m.addConstr(v["E_sell"] <= M_big * (1 - v["y_buy"]), name="CCT_sell_on")
    c_buy = m.addVar(name="C_buy")
    for k in range(5):
        slope = p.lam * (1 + k * p.alpha_step)
        icpt = p.lam * p.l_step * (k + p.alpha_step * k * (k - 1) / 2)
        m.addConstr(c_buy >= slope * (v["E_buy"] - k * p.l_step) + icpt, name=f"CCT_seg{k}")
    v["cct"] = m.addVar(lb=-inf, name="CCT")
    m.addConstr(v["cct"] == c_buy - p.sell_factor * p.lam * v["E_sell"], name="CCT_def")
    e["E_a"] = E_a

    # ---- 目标函数 Eq.(12)–(17) ----
    if p.om_basis == "capacity":
        om_conv = (p.a_GT * p.PGT_max + p.a_GB * p.PGB_max + p.a_WHB * p.PWHB_max
                   + p.a_EL * p.PEL_max + p.a_MR * p.HMR_max + p.a_HFC * p.HHFC_max)
    else:
        om_conv = grb.quicksum(
            p.a_GT * v["gt_e"][t] + p.a_GB * v["gb_h"][t] + p.a_WHB * e["whb_h"][t]
            + p.a_EL * v["el_e"][t] + p.a_MR * e["mr_g"][t] + p.a_HFC * e["hfc_P"][t] for t in R) * DT
    om_other = grb.quicksum(
        p.a_CCS * e["ccs_e"][t] + p.a_WT * v["wt"][t] + p.a_PV * v["pv"][t]
        + grb.quicksum(s.alpha * (cha(n, t) + dis(n, t)) for n, s in enumerate(p.storages))
        for t in R) * DT
    COP = om_conv + om_other
    CEP = grb.quicksum(
        p.price_elec[t] * v["buy_e"][t] + p.price_heat * v["buy_h"][t]
        + p.price_gas * v["buy_g"][t] + p.price_H2 * p.meh * v["buy_H"][t]
        for t in R) * DT
    CWS = grb.quicksum(p.pen_WT * e["wt_cut"][t] + p.pen_PV * e["pv_cut"][t] for t in R) * DT
    CCS = grb.quicksum(p.k_cs * e["co2_cs"][t] for t in R)
    e["costs"] = {"COP": COP, "CCT": v["cct"], "CEP": CEP, "CWS": CWS, "CCS": CCS}
    m.setObjective(COP + v["cct"] + CEP + CWS + CCS, GRB.MINIMIZE)
    return m, v, e


# =========================
# 3) 求解与结果整理
# =========================
@dataclass
class Result:
    status: int
    total: float = float("nan")
    costs: Dict[str, float] = field(default_factory=dict)
    summary: Dict[str, float] = field(default_factory=dict)
    df: Optional[pd.DataFrame] = None

    @property
    def ok(self) -> bool:
        return self.status == GRB.OPTIMAL


def _val(x) -> float:
    if hasattr(x, "getValue"):
        return x.getValue()
    if hasattr(x, "X"):
        return x.X
    return float(x)


def solve(p: Optional[Params] = None, mode: str = "paper", verbose: bool = False) -> Result:
    """求解第 4 节的 24 h 优化调度。"""
    p = p or Params()
    m, v, e = build_model(p, mode, verbose)
    m.optimize()
    if m.Status != GRB.OPTIMAL:
        return Result(status=m.Status)

    R = range(T)

    def col(xs):
        return [_val(xs[t]) for t in R]

    df = pd.DataFrame({"t": list(R)})
    # 电
    df["E_Load"] = p.load_e
    df["E_Buy"], df["WT"], df["PV"] = col(v["buy_e"]), col(v["wt"]), col(v["pv"])
    df["GT_e"], df["HFC_e"] = col(v["gt_e"]), col(e["hfc_e"])
    df["EL_e"], df["CCS_e"] = col(v["el_e"]), col(e["ccs_e"])
    df["WT_cut"], df["PV_cut"] = col(e["wt_cut"]), col(e["pv_cut"])
    # 热
    df["H_Load"] = p.load_h
    df["H_Buy"], df["WHB_h"], df["GB_h"] = col(v["buy_h"]), col(e["whb_h"]), col(v["gb_h"])
    df["HFC_h"] = col(e["hfc_h"])
    # 气
    df["G_Load"] = p.load_g
    df["G_Buy"], df["MR_g"], df["GT_g"], df["GB_g"] = col(v["buy_g"]), col(e["mr_g"]), col(e["gt_g"]), col(e["gb_g"])
    # 氢
    df["H2_Load"] = p.load_H
    df["H2_Buy"], df["EL_H2"] = col(v["buy_H"]), col(e["el_H"])
    df["HFC_H2"], df["MR_H2"] = col(v["hfc_H"]), col(v["mr_H"])
    # 储能
    for n in range(len(p.storages)):
        df[f"ES{n+1}_cha"] = [v["cha"][n, t].X for t in R]
        df[f"ES{n+1}_dis"] = [v["dis"][n, t].X for t in R]
        df[f"SOC{n+1}"] = [v["soc"][n, t].X for t in R]
    # 碳
    df["CO2_GT"], df["CO2_GB"] = col(e["co2_gt"]), col(e["co2_gb"])
    df["CO2_cap"], df["CO2_uncap"] = col(e["co2_cap"]), col(e["co2_uncap"])
    df["CO2_MR"], df["CO2_CS"], df["CO2_env"] = col(e["co2_mr"]), col(e["co2_cs"]), col(e["co2_env"])
    num = df.columns.drop("t")
    df[num] = df[num].round(9) + 0.0   # 去掉求解器残留的 -0.0

    costs = {k: _val(x) for k, x in e["costs"].items()}
    summary = {
        "CO2 产生量 / t": float(df["CO2_GT"].sum() + df["CO2_GB"].sum()),
        "CO2 排放量 / t": float(df["CO2_uncap"].sum()),
        "CCS 耗电 / MWh": float(df["CCS_e"].sum()),
        "CCS 运维成本 / ¥": float(p.a_CCS * df["CCS_e"].sum()),
        "参与交易净排放 / t": _val(e["E_a"]),
        "弃风弃光 / MWh": float(df["WT_cut"].sum() + df["PV_cut"].sum()),
    }
    for n, s in enumerate(p.storages):
        summary[f"ΔS{n+1} {s.name} S(1)−S(T)"] = float(df[f"SOC{n+1}"].iloc[0] - df[f"SOC{n+1}"].iloc[-1])
    return Result(status=m.Status, total=m.ObjVal, costs=costs, summary=summary, df=df)


def compare_with_paper(r: Result) -> pd.DataFrame:
    """把本模型结果和论文第 4 节报告值并排列出。"""
    ours = {
        "总成本": r.total,
        "外购能源成本 CEP": r.costs["CEP"],
        "运维成本 COP": r.costs["COP"],
        "碳交易成本 CCT": r.costs["CCT"],
        "弃风弃光成本 CWS": r.costs["CWS"],
        "碳封存成本 CCS": r.costs["CCS"],
        "CO2 产生量 / t": r.summary["CO2 产生量 / t"],
        "CO2 排放量 / t": r.summary["CO2 排放量 / t"],
        "CCS 耗电 / MWh": r.summary["CCS 耗电 / MWh"],
    }
    rows = [(k, ours[k], PAPER_RESULTS[k]) for k in PAPER_RESULTS]
    out = pd.DataFrame(rows, columns=["指标", "本模型", "论文"]).set_index("指标")
    out["相对偏差 %"] = (out["本模型"] - out["论文"]) / out["论文"].abs() * 100
    return out


def print_report(r: Result):
    names = {"CEP": "外购能源成本", "COP": "运维成本", "CCT": "阶梯碳交易成本",
             "CWS": "弃风弃光惩罚", "CCS": "碳封存成本"}
    print(f"调度总成本 / ¥: {r.total:,.1f}")
    for k, name in names.items():
        print(f"  {name} {k} / ¥: {r.costs[k]:,.1f}")
    for k, x in r.summary.items():
        print(f"  {k}: {x:,.2f}")


# =========================
# 4) 第 5 节：容量配置
# =========================
def with_capacities(p: Params, **caps) -> Params:
    """返回修改了设备容量的新参数，例如 with_capacities(p, PGT_max=254.1)。"""
    return replace(p, **caps)


def capacity_cost(caps: Dict[str, float], p: Optional[Params] = None, mode: str = "paper") -> float:
    """给定设备容量下最优调度的总成本（不可行返回 inf）。"""
    r = solve(with_capacities(p or Params(), **caps), mode)
    return r.total if r.ok else float("inf")


def capacity_sweep(device: str, values: Sequence[float], p: Optional[Params] = None,
                   mode: str = "paper") -> pd.DataFrame:
    """论文 Fig.5：单一设备容量变化时，最优调度下的总运行成本。"""
    key = CAPACITY_KEYS[device]
    rows = [(float(x), capacity_cost({key: float(x)}, p, mode)) for x in values]
    return pd.DataFrame(rows, columns=[key, "总成本"])


def optimize_single(device: str, bounds: tuple, p: Optional[Params] = None, mode: str = "paper",
                    points: int = 31, rounds: int = 3) -> tuple:
    """论文 Table 4：单设备容量寻优。一维问题用逐级加密的网格搜索代替 PSO/GA，
    返回 (最优容量, 最低总成本)。"""
    lo, hi = bounds
    xs = np.linspace(lo, hi, points)
    best = (lo, float("inf"))
    for _ in range(rounds):
        df = capacity_sweep(device, xs, p, mode)
        i = int(df["总成本"].idxmin())
        best = (float(df.iloc[i, 0]), float(df.iloc[i, 1]))
        step = xs[1] - xs[0]
        xs = np.linspace(max(lo, best[0] - step), min(hi, best[0] + step), 21)
    return best


def pso_capacities(bounds: Dict[str, tuple], p: Optional[Params] = None, mode: str = "paper",
                   n_particles: int = 20, iters: int = 30, seed: int = 0,
                   w: float = 0.7, c1: float = 1.5, c2: float = 1.5, verbose: bool = True):
    """论文 5.2 节：多设备容量同时寻优（粒子群算法）。
    bounds 形如 {"GT": (0, 600), "EL": (0, 100), ...}。返回 (最优容量 dict, 最低总成本, 收敛历史)。"""
    rng = np.random.default_rng(seed)
    keys = [CAPACITY_KEYS[d] for d in bounds]
    lo = np.array([b[0] for b in bounds.values()], dtype=float)
    hi = np.array([b[1] for b in bounds.values()], dtype=float)
    vmax = 0.2 * (hi - lo)

    def f(x):
        return capacity_cost(dict(zip(keys, x)), p, mode)

    x = lo + rng.random((n_particles, len(keys))) * (hi - lo)
    vel = np.zeros_like(x)
    pbest, pcost = x.copy(), np.array([f(xi) for xi in x])
    g = int(np.argmin(pcost))
    gbest, gcost = pbest[g].copy(), pcost[g]
    history = [gcost]
    for it in range(iters):
        r1, r2 = rng.random(x.shape), rng.random(x.shape)
        vel = np.clip(w * vel + c1 * r1 * (pbest - x) + c2 * r2 * (gbest - x), -vmax, vmax)
        x = np.clip(x + vel, lo, hi)
        cost = np.array([f(xi) for xi in x])
        better = cost < pcost
        pbest[better], pcost[better] = x[better], cost[better]
        g = int(np.argmin(pcost))
        if pcost[g] < gcost:
            gbest, gcost = pbest[g].copy(), pcost[g]
        history.append(gcost)
        if verbose:
            print(f"  PSO 第 {it + 1:>2d}/{iters} 代：最低总成本 {gcost:,.1f}")
    return dict(zip(keys, gbest.tolist())), gcost, history


def section5_comparison(p: Optional[Params] = None, mode: str = "paper") -> pd.DataFrame:
    """在论文 Table 4、Table 6 给出的优化容量下求解，比较成本相对基准的变化幅度。"""
    p = p or Params()
    base = solve(p, mode).total
    paper_base = PAPER_RESULTS["总成本"]
    rows = []
    for dev, (cap, paper_cost) in PAPER_TABLE4.items():
        cost = capacity_cost({CAPACITY_KEYS[dev]: cap}, p, mode)
        rows.append((f"{dev} = {cap:g}", cost, (cost / base - 1) * 100, paper_cost,
                     (paper_cost / paper_base - 1) * 100))
    cost = capacity_cost(PAPER_OPT_CAPACITY, p, mode)
    rows.append(("Table 6 六设备", cost, (cost / base - 1) * 100, PAPER_OPT_COST,
                 (PAPER_OPT_COST / paper_base - 1) * 100))
    return pd.DataFrame(rows, columns=["容量方案", "本模型总成本", "本模型降幅 %", "论文总成本", "论文降幅 %"]
                        ).set_index("容量方案")


# =========================
# 5) 绘图（与论文 Fig.4 同样的堆叠柱状图）
# =========================
COLOR_MAP = {
    "外部购电": "#00AEEF", "外部购气": "#00AEEF", "外部购氢": "#00AEEF", "外部购热": "#00AEEF",
    "风机出力": "#FFC000", "光伏出力": "#0A562C",
    "燃气轮机": "#ED1C24", "燃气锅炉": "#ED1C24", "甲烷发生器": "#F4B183",
    "余热锅炉": "#00B050", "电解槽制氢": "#00B050", "碳捕集耗电": "#92D050",
    "氢燃料电池": "#99CCFF", "氢燃料电池热": "#99CCFF",
    "蓄电池放电": "#7F7F7F", "蓄热放热": "#7F7F7F", "储气放气": "#7F7F7F", "储氢放氢": "#7F7F7F",
    "蓄电池充电": "#FF3399", "蓄热储热": "#FF3399", "储气充气": "#FF3399", "储氢充氢": "#FF3399",
    "电解槽耗电": "#7030A0", "燃气轮机耗气": "#0700CD", "燃气锅炉耗气": "#7030A0",
    "燃料电池耗氢": "#7030A0", "甲烷发生器耗氢": "#C55A11",
    "CCS": "#3399FF", "Non-CCS": "#C55A11", "GT": "#33CC33", "GB": "#FF1F1F",
    "Carbon Capture": "#3399FF", "Carbon Storage": "#33CC33", "MR": "#FF1F1F",
}


def _plt():
    import logging
    import matplotlib.pyplot as plt
    logging.getLogger("matplotlib.font_manager").setLevel(logging.ERROR)
    plt.rcParams["font.sans-serif"] = ["SimHei", "Microsoft YaHei", "PingFang SC", "WenQuanYi Zen Hei",
                                       "Noto Sans CJK SC", "Source Han Sans SC", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    return plt


def _stack(ax, x, parts, sign):
    bottom = np.zeros(len(x))
    for name, vals in parts.items():
        vals = sign * np.asarray(vals, dtype=float)
        ax.bar(x, vals, bottom=bottom, label=name, color=COLOR_MAP.get(name, "#A6A6A6"),
               edgecolor="black", linewidth=0.5, zorder=2)
        bottom += vals


def _balance_fig(df, pos, neg, load, title, ylabel, path=None):
    plt = _plt()
    x = df["t"].to_numpy()
    fig, ax = plt.subplots(figsize=(6.09, 5.21), dpi=100)
    _stack(ax, x, pos, 1)
    _stack(ax, x, neg, -1)
    if load is not None:
        ax.plot(x, load, color="#ED1C24", marker="o", markerfacecolor="none", markersize=4,
                linewidth=1.5, label="负荷需求", zorder=10)
    ax.set_title(title, fontsize=11, fontweight="bold")
    ax.set_xlabel("Time/hour", fontsize=10)
    ax.set_ylabel(ylabel, fontsize=10)
    ax.tick_params(axis="both", direction="in", top=True, right=True, labelsize=9)
    ax.axhline(0, color="black", linewidth=0.8, zorder=3)
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.14), ncol=3, frameon=True,
              edgecolor="black", fontsize=8)
    fig.tight_layout()
    if path:
        fig.savefig(path, dpi=150, bbox_inches="tight")
        plt.close(fig)
    return fig


def plot_all(df: pd.DataFrame, outdir: Optional[str] = None):
    """绘制电/热/气/氢平衡与碳捕集/封存共 6 张图（对应论文 Fig.4(a)–(f)）；给出 outdir 时保存为 PNG。"""
    def f(name):
        return os.path.join(outdir, name) if outdir else None

    return [
        _balance_fig(df, {"外部购电": df["E_Buy"], "风机出力": df["WT"], "光伏出力": df["PV"],
                          "燃气轮机": df["GT_e"], "氢燃料电池": df["HFC_e"], "蓄电池放电": df["ES1_dis"]},
                     {"电解槽耗电": df["EL_e"], "蓄电池充电": df["ES1_cha"], "碳捕集耗电": df["CCS_e"]},
                     df["E_Load"], "电负荷能量平衡图", "Power/MW", f("elec_balance.png")),
        _balance_fig(df, {"外部购热": df["H_Buy"], "余热锅炉": df["WHB_h"], "燃气锅炉": df["GB_h"],
                          "氢燃料电池热": df["HFC_h"], "蓄热放热": df["ES2_dis"]},
                     {"蓄热储热": df["ES2_cha"]},
                     df["H_Load"], "热负荷能量平衡图", "Power/MW", f("heat_balance.png")),
        _balance_fig(df, {"外部购气": df["G_Buy"], "甲烷发生器": df["MR_g"], "储气放气": df["ES3_dis"]},
                     {"储气充气": df["ES3_cha"], "燃气轮机耗气": df["GT_g"], "燃气锅炉耗气": df["GB_g"]},
                     df["G_Load"], "天然气平衡分析图", "Power/MW", f("gas_balance.png")),
        _balance_fig(df, {"外部购氢": df["H2_Buy"], "电解槽制氢": df["EL_H2"], "储氢放氢": df["ES4_dis"]},
                     {"储氢充氢": df["ES4_cha"], "燃料电池耗氢": df["HFC_H2"], "甲烷发生器耗氢": df["MR_H2"]},
                     df["H2_Load"], "氢能平衡分析图", "Mass/kg", f("hydrogen_balance.png")),
        _balance_fig(df, {"CCS": df["CO2_cap"], "Non-CCS": df["CO2_uncap"]},
                     {"GT": df["CO2_GT"], "GB": df["CO2_GB"]},
                     None, "Carbon Capture Status", "Mass/t", f("carbon_cap.png")),
        _balance_fig(df, {"Carbon Capture": df["CO2_cap"]},
                     {"Carbon Storage": df["CO2_CS"], "MR": df["CO2_MR"]},
                     None, "Carbon Storage Status", "Mass/t", f("carbon_storage.png")),
    ]


def plot_sweeps(sweeps: Dict[str, pd.DataFrame], path: Optional[str] = None):
    """论文 Fig.5：各设备容量与最优调度总成本的关系（2×3 子图）。"""
    plt = _plt()
    fig, axes = plt.subplots(2, 3, figsize=(12, 6.5), dpi=100)
    for ax, (dev, df) in zip(axes.flat, sweeps.items()):
        ax.plot(df.iloc[:, 0], df["总成本"] / 1e4, color="#1f77b4", linewidth=1.5)
        i = int(df["总成本"].idxmin())
        ax.plot(df.iloc[i, 0], df.iloc[i, 1] / 1e4, "o", color="#ED1C24")
        ax.annotate(f"{df.iloc[i, 0]:.1f}, {df.iloc[i, 1] / 1e4:.2f}", (df.iloc[i, 0], df.iloc[i, 1] / 1e4),
                    textcoords="offset points", xytext=(6, 8), fontsize=8)
        unit = "kg" if dev in ("MR", "HFC") else "MW"
        ax.set_xlabel(f"{dev} 容量 / {unit}", fontsize=9)
        ax.set_ylabel("总成本 / 10⁴ ¥", fontsize=9)
        ax.tick_params(direction="in", labelsize=8)
        ax.grid(alpha=0.3)
    fig.tight_layout()
    if path:
        fig.savefig(path, dpi=150, bbox_inches="tight")
        plt.close(fig)
    return fig


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="电–热–气–氢 IES 优化调度与容量配置（论文复现）")
    ap.add_argument("--mode", choices=STORAGE_MODES, default="paper", help="储能首末口径（默认 paper）")
    ap.add_argument("--literal", action="store_true", help="按论文公式字面实现（出售价 λ、运维按出力计）")
    ap.add_argument("--plot", metavar="DIR", help="把 6 张结果图保存到该目录（如 pic）")
    ap.add_argument("--section5", action="store_true", help="计算论文 Table 4/6 容量方案下的成本变化")
    args = ap.parse_args()

    params = Params.literal() if args.literal else Params()
    res = solve(params, mode=args.mode)
    if not res.ok:
        raise SystemExit(f"未得到最优解，status = {res.status}")
    print_report(res)
    print("\n与论文第 4 节结果对比：")
    print(compare_with_paper(res).to_string(float_format=lambda x: f"{x:,.2f}"))
    if args.plot:
        os.makedirs(args.plot, exist_ok=True)
        plot_all(res.df, args.plot)
        print(f"\n结果图已保存到 {args.plot}/")
    if args.section5:
        print("\n第 5 节：论文优化容量下的成本变化（相对各自基准）：")
        print(section5_comparison(params, args.mode).to_string(float_format=lambda x: f"{x:,.2f}"))
