/* ============================================================================
   Промавтоматика · рушій орієнтовного розрахунку генерації та вартості
   Версія 2.0. Чистий JS, без залежностей. Кожна функція тестується окремо.
   ========================================================================== */
/* ВЕБ-ВЕРСІЯ: розрахунок ЦІНИ (calculatePrice, PRICE_PER_KWP_USD, BATTERY_PRICE_PER_KWH_USD)
   звідси ПРИБРАНО. Ціна рахується на сервері — Supabase RPC calculate_quote().
   Усе інше (генерація, кліпінг, АКБ за datasheet) — без змін від v2.0. */

const PRICE_DISCLAIMER =
  "Розрахунок є попереднім. Остаточна вартість визначається після обстеження об'єкта, " +
  "де будуть зроблені точні заміри точок підключення, довжини трас та уточнена комплектація " +
  "необхідних матеріалів.";

const CALC_DISCLAIMER =
  "Фактична генерація залежить від локації, орієнтації модулів, погодних умов, затінення, " +
  "обладнання та системних втрат. Розрахунок не є проєктним моделюванням у PVsyst.";

/* --------------------------------------------------------------- ОДИНИЦІ */
function toKwp(value, unit) {
  const v = Number(value);
  if (!isFinite(v)) return 0;
  return unit === "MW" ? v * 1000 : v;
}

/* ------------------------------------------------- ПОГОДИННИЙ ПРОФІЛЬ */
/* Місячні питомі значення (кВт·год на 1 кВт) розподіляються по годинах року за
   геометрією Сонця. Сума за місяць зберігається точно — змінюється лише
   внутрішньодобова форма, потрібна для оцінки кліпінгу.                    */

const DAYS_IN_MONTH = [31,28,31,30,31,30,31,31,30,31,30,31];
const MONTH_LABELS = ["Січень","Лютий","Березень","Квітень","Травень","Червень",
                      "Липень","Серпень","Вересень","Жовтень","Листопад","Грудень"];

const rad = d => d * Math.PI / 180;

function cosIncidence(lat, decl, hourAngle, tilt, azimuth) {
  const φ = rad(lat), δ = rad(decl), ω = rad(hourAngle), β = rad(tilt), γ = rad(azimuth);
  return Math.sin(δ)*Math.sin(φ)*Math.cos(β)
       - Math.sin(δ)*Math.cos(φ)*Math.sin(β)*Math.cos(γ)
       + Math.cos(δ)*Math.cos(φ)*Math.cos(β)*Math.cos(ω)
       + Math.cos(δ)*Math.sin(φ)*Math.sin(β)*Math.cos(γ)*Math.cos(ω)
       + Math.cos(δ)*Math.sin(β)*Math.sin(γ)*Math.sin(ω);
}

/** Повертає масив 12 місяців, кожен — масив погодинних питомих значень (кВт·год на 1 кВт). */
function buildHourlySpecificProfile(monthlySpecificYield, opts) {
  const lat = (opts && opts.latitude) != null ? opts.latitude : 49.23;   // Вінниця
  const tilt = (opts && opts.tilt) != null ? opts.tilt : 30;
  const azimuth = (opts && opts.azimuth) != null ? opts.azimuth : 0;     // 0 = південь
  const out = [];
  let dayOfYear = 0;
  for (let m = 0; m < 12; m++) {
    const hours = [];
    let raw = 0;
    for (let d = 0; d < DAYS_IN_MONTH[m]; d++) {
      dayOfYear++;
      const decl = 23.45 * Math.sin(rad(360 * (284 + dayOfYear) / 365));
      for (let h = 0; h < 24; h++) {
        const ω = 15 * (h + 0.5 - 12);
        const cosZ = Math.sin(rad(lat))*Math.sin(rad(decl))
                   + Math.cos(rad(lat))*Math.cos(rad(decl))*Math.cos(rad(ω));
        let v = 0;
        if (cosZ > 0.01) {
          const ci = cosIncidence(lat, decl, ω, tilt, azimuth);
          if (ci > 0) {
            // проста модель ясного неба: послаблення в атмосфері за масою повітря
            const airMass = 1 / cosZ;
            v = ci * Math.pow(0.7, Math.pow(airMass, 0.678));
          }
        }
        hours.push(v); raw += v;
      }
    }
    const target = monthlySpecificYield[m] || 0;
    const k = raw > 0 ? target / raw : 0;
    out.push(hours.map(v => v * k));
  }
  return out;
}


/* ============================================================================
   АКБ ДЛЯ ГІБРИДНОЇ СЕС — розрахунок за datasheet, а не за правилом «кВт·год = кВт»

   Джерела (перевірено 07.08.2026):
   · Deye SUN-29.9/30/35/40/50K-SG01HP3-EU-BM3/BM4 datasheet:
       Battery Voltage Range 160–800 V · Number of Battery Input: 2 ·
       Max. Charging Current 50+50 A · Max. Discharging Current 50+50 A ·
       Max. 10 pcs parallel · Peak Power (off-grid) 1.5 × rated, 10 s
   · Deye SUN-100/125K-SG02HP3-EU-GM8/GM10 datasheet:
       Battery Voltage Range 160–1000 V · Number of Battery Input: 2 ·
       Max. Charging/Discharging Current 200 A (100+100)
   · Deye BOS-G V1.4 datasheet:
       модуль 51,2 В / 100 А·год / 5,12 кВт·год ·
       кластер 3 (мін) / 8 (US) / 12 (EU) модулів у серію ·
       номінальна напруга 153,6 / 409,6 / 614,4 В ·
       робоча напруга 124,8–175,2 / 332,8–467,2 / 499,2–700 В ·
       струм: рекомендований 50 А, номінальний 100 А, пік 125 А (2 хв) ·
       control box HVB750V/100A: 120–750 В, ном. 100 А, макс. 125 А ·
       стійка 3U-LRACK — 8 модулів + 1 control box, 3U-HRACK — 12 модулів + 1

   ГОЛОВНЕ: батарея віддає потужність як добуток напруги стека на струм.
   Струм обмежений входом інвертора, напруга — кількістю модулів у серії.
   Ємність у кВт·год визначає ТРИВАЛІСТЬ роботи, а не потужність.
   ========================================================================== */

const DEYE_HYBRID_HV = [
  { from: 29.9, to: 50,  inputs: 2, aPerInput: 50,  vMin: 160, vMax: 800,
    series: "SG01HP3-BM3/BM4", source: "datasheet 231218" },
  { from: 60,   to: 80,  inputs: 2, aPerInput: 80,  vMin: 160, vMax: 800,
    series: "SG02HP3-EM6", source: "потребує звірки з datasheet" },
  { from: 100,  to: 125, inputs: 2, aPerInput: 100, vMin: 160, vMax: 1000,
    series: "SG02HP3-GM8/GM10", source: "datasheet 20260423" },
];

const BOS_G = { moduleV: 51.2, moduleKwh: 5.12, minModules: 3, maxModules: 12,
                controlBoxVMax: 750, controlBoxA: 100, usableDoD: 0.9,
                model: "Deye BOS-G", controlBox: "HVB750V/100A-EU" };

function deyeHybridLimits(acKw) {
  for (const r of DEYE_HYBRID_HV) if (acKw >= r.from - 0.1 && acKw <= r.to + 0.1) return r;
  return DEYE_HYBRID_HV[acKw < 29.9 ? 0 : DEYE_HYBRID_HV.length - 1];
}

/**
 * Підбирає конфігурацію BOS-G під потрібну резервну потужність.
 * @param acKw            номінал гібридного інвертора, кВт
 * @param backupKw        потужність, яку треба тримати при зникненні мережі
 * @param bat             параметри батареї (за замовчуванням BOS-G)
 */
function sizeHybridBattery(acKw, backupKw, bat) {
  const B = bat || BOS_G;
  const lim = deyeHybridLimits(acKw);
  const notes = [], errors = [];
  const target = Math.min(backupKw > 0 ? backupKw : acKw, acKw);

  // Стеля напруги — менше з обмеження інвертора і control box
  const vCeil = Math.min(lim.vMax, B.controlBoxVMax);
  const maxModulesByV = Math.floor(vCeil / B.moduleV);
  const maxModules = Math.min(B.maxModules, maxModulesByV);

  let chosen = null;
  for (let clusters = 1; clusters <= lim.inputs && !chosen; clusters++) {
    const aTotal = clusters * B.controlBoxA >= clusters * lim.aPerInput
                 ? clusters * lim.aPerInput : clusters * B.controlBoxA;
    const needV = target * 1000 / aTotal;
    const mods = Math.ceil(needV / B.moduleV);
    if (mods >= B.minModules && mods <= maxModules)
      chosen = { clusters, modulesPerCluster: mods, aTotal };
  }

  if (!chosen) {
    const clusters = lim.inputs;
    const aTotal = clusters * Math.min(lim.aPerInput, B.controlBoxA);
    chosen = { clusters, modulesPerCluster: maxModules, aTotal };
    errors.push("Повну резервну потужність " + target.toFixed(0) + " кВт на " + B.model +
      " досягти не вдається: максимум " + maxModules + " модулів у кластері (" +
      (maxModules * B.moduleV).toFixed(0) + " В) і " + lim.inputs + " входи АКБ. " +
      "Потрібна інша батарея або зменшення резервованого навантаження.");
  }

  const vCluster = chosen.modulesPerCluster * B.moduleV;
  const totalModules = chosen.clusters * chosen.modulesPerCluster;
  const totalKwh = +(totalModules * B.moduleKwh).toFixed(2);
  const usableKwh = +(totalKwh * B.usableDoD).toFixed(2);
  const backupPowerKw = +(vCluster * chosen.aTotal / 1000).toFixed(1);

  if (vCluster < lim.vMin)
    errors.push("Напруга стека " + vCluster.toFixed(0) + " В нижча за мінімальну для інвертора (" +
      lim.vMin + " В). Стек не запуститься.");
  if (chosen.clusters > 1)
    notes.push("Потрібно " + chosen.clusters + " незалежні кластери — по одному на кожен вхід АКБ інвертора.");
  notes.push("Control box " + B.controlBox + " — " + chosen.clusters + " шт, по одному на кластер. " +
             "У комплект інвертора не входить.");

  return {
    inverterAcKw: acKw, series: lim.series, batteryInputs: lim.inputs,
    aPerInput: lim.aPerInput, currentSource: lim.source,
    targetBackupKw: target,
    clusters: chosen.clusters, modulesPerCluster: chosen.modulesPerCluster,
    totalModules, clusterVoltage: +vCluster.toFixed(1),
    totalKwh, usableKwh, backupPowerKw,
    controlBoxQty: chosen.clusters, controlBox: B.controlBox,
    autonomyHoursAtBackup: target > 0 ? +(usableKwh / target).toFixed(1) : null,
    notes, errors
  };
}

/* ------------------------------------------------- ККД ІНВЕРТОРА */
function efficiencyAt(loadRatio, curve, flatEfficiency) {
  if (!curve || !curve.length) return flatEfficiency;
  const c = curve.slice().sort((a, b) => a.load - b.load);
  if (loadRatio <= c[0].load) return c[0].efficiency;
  if (loadRatio >= c[c.length - 1].load) return c[c.length - 1].efficiency;
  for (let i = 0; i < c.length - 1; i++) {
    if (loadRatio >= c[i].load && loadRatio <= c[i + 1].load) {
      const t = (loadRatio - c[i].load) / (c[i + 1].load - c[i].load);
      return c[i].efficiency + t * (c[i + 1].efficiency - c[i].efficiency);
    }
  }
  return flatEfficiency;
}

/* ------------------------------------------------- ГОЛОВНИЙ РОЗРАХУНОК */
/**
 * @param {object} p
 *   installedDcKwp, inverterUnitAcKw, inverterQuantity, inverterModel,
 *   inverterEfficiency, efficiencyCurve, gridExportLimitKw,
 *   monthlySpecificYield [12], profileMode: "hourly"|"monthly",
 *   profileIsAcSide (bool), latitude, tilt, azimuth, locationId
 */
function calculateGeneration(p) {
  const warnings = [];
  const installedDcKwp = Number(p.installedDcKwp) || 0;
  const inverterUnitAcKw = Number(p.inverterUnitAcKw) || 0;
  const inverterQuantity = Number(p.inverterQuantity) || 0;
  const inverterTotalAcKw = inverterUnitAcKw * inverterQuantity;
  const eff = p.inverterEfficiency != null ? Number(p.inverterEfficiency) : 0.98;
  const exportLimit = p.gridExportLimitKw != null && p.gridExportLimitKw !== ""
                    ? Number(p.gridExportLimitKw) : null;
  const profileIsAcSide = !!p.profileIsAcSide;

  if (!(installedDcKwp > 0)) warnings.push("Потужність фотомодулів має бути більшою за 0.");
  if (!(inverterTotalAcKw > 0)) warnings.push("Сумарна потужність інверторів має бути більшою за 0.");
  if (!Number.isInteger(inverterQuantity) || inverterQuantity <= 0)
    warnings.push("Кількість інверторів має бути додатним цілим числом.");
  if (eff <= 0.5 || eff > 1)
    warnings.push("ККД інвертора поза допустимим діапазоном (0,5–1,0). Перевірте значення.");
  if (exportLimit !== null && exportLimit <= 0)
    warnings.push("Ліміт видачі в мережу має бути більшим за 0 або порожнім.");
  if (exportLimit !== null && exportLimit > inverterTotalAcKw)
    warnings.push("Ліміт видачі перевищує сумарну потужність інверторів — обмеження не спрацює.");

  const dcAcRatio = inverterTotalAcKw > 0 ? installedDcKwp / inverterTotalAcKw : 0;
  if (dcAcRatio && dcAcRatio < 0.7)
    warnings.push("DC/AC = " + dcAcRatio.toFixed(2) + ". Інвертори суттєво недовантажені — перевірте конфігурацію.");
  if (dcAcRatio > 2)
    warnings.push("DC/AC = " + dcAcRatio.toFixed(2) + ". Дуже високе перевантаження — очікуються великі втрати на кліпінгу.");

  const monthly = [];
  let accuracy, annualClipping = 0, annualExportLoss = 0;

  if (p.profileMode === "hourly") {
    const prof = buildHourlySpecificProfile(p.monthlySpecificYield,
      { latitude: p.latitude, tilt: p.tilt, azimuth: p.azimuth });
    for (let m = 0; m < 12; m++) {
      let gen = 0, clip = 0, exp = 0;
      for (const spec of prof[m]) {
        const availableDc = spec * installedDcKwp;          // кВт·год за годину
        let potentialAc;
        if (profileIsAcSide) {
          potentialAc = availableDc;                        // втрати вже в профілі
        } else {
          const load = inverterTotalAcKw > 0 ? availableDc / inverterTotalAcKw : 0;
          potentialAc = availableDc * efficiencyAt(load, p.efficiencyCurve, eff);
        }
        const invLimit = inverterTotalAcKw * 1;             // interval_hours = 1
        const afterInv = Math.min(potentialAc, invLimit);
        clip += Math.max(0, potentialAc - invLimit);
        let grid = afterInv;
        if (exportLimit !== null && exportLimit > 0) {
          const gLimit = exportLimit * 1;
          grid = Math.min(afterInv, gLimit);
          exp += Math.max(0, afterInv - gLimit);
        }
        gen += grid;
      }
      monthly.push({ monthNumber: m + 1, monthLabel: MONTH_LABELS[m],
                     generationKwh: gen, clippingLossKwh: clip,
                     exportLimitLossKwh: exportLimit !== null ? exp : null });
      annualClipping += clip; annualExportLoss += exp;
    }
    accuracy = (p.efficiencyCurve && p.efficiencyCurve.length && p.locationId
                && p.tilt != null && p.azimuth != null) ? "high" : "medium";
    warnings.push("Внутрішньодобовий розподіл змодельовано за геометрією Сонця, а не взято з " +
                  "експорту PVsyst. Місячні суми збережено точно, кліпінг є орієнтовною оцінкою.");
    if (p.tilt != null || p.azimuth != null)
      warnings.push("Кут нахилу та азимут впливають лише на форму доби. Річна сума береться з " +
                    "нормалізованого профілю і не перераховується під орієнтацію.");
  } else {
    for (let m = 0; m < 12; m++) {
      const base = (p.monthlySpecificYield[m] || 0) * installedDcKwp;
      const gen = profileIsAcSide ? base : base * eff;
      monthly.push({ monthNumber: m + 1, monthLabel: MONTH_LABELS[m],
                     generationKwh: gen, clippingLossKwh: null, exportLimitLossKwh: null });
    }
    accuracy = "medium";   /* місячний профіль — єдиний режим з 04.09.2026; кліпінг не оцінюється */
    annualClipping = null; annualExportLoss = null;
  }

  const annualGenerationKwh = monthly.reduce((s, x) => s + x.generationKwh, 0);
  const ACCURACY_TEXT = { high: "Висока точність орієнтовної моделі",
                          medium: "Орієнтовна оцінка на основі типового профілю",
                          low: "Попередня орієнтовна оцінка" };

  return {
    installedDcKwp, inverterUnitAcKw, inverterQuantity, inverterTotalAcKw,
    inverterModel: p.inverterModel || null,
    dcAcRatio,
    annualGenerationKwh,
    annualSpecificGenerationKwhKwp: installedDcKwp > 0 ? annualGenerationKwh / installedDcKwp : 0,
    annualClippingLossKwh: annualClipping,
    annualExportLimitLossKwh: exportLimit !== null ? annualExportLoss : null,
    calculationAccuracy: accuracy,
    calculationAccuracyText: ACCURACY_TEXT[accuracy],
    calculationDisclaimer: CALC_DISCLAIMER,
    warnings,
    monthlyGeneration: monthly
  };
}

