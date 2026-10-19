---Main for 13/10
/* =====================================================================
   QC07 FOLLOW TRACKING - BAN TOI UU (Power BI)
   Ky: 1 thang den het hom nay. Giu TAT CA HD khop call/offer/Ops, ke ca HD QC07 an.
   Grain: 1 dong / CUID + CONTRACT_CODE + Ops; chua khop HD thi hien HD NULL.
   T      = Manual Outbound / Personal Callback GAN NHAT / CUID + HD + Ops.
   T0     = Inbound / Outbound SOM NHAT truoc T (cung CUID + Ops), co the NULL
   Step 1 = 1 khi T - T0 <= 14 ngay; > 14 ngay hoac khong co T0 -> 0
   Step 2 = cung Ops: T - BOD1 <= 30 hoac T - BOD2 <= 180; khong chan BOD sau T
   Step 3 = HD tu IB/OB -> 1; con lai xet TAT CA BOD1/BOD2 lien quan TLS
            trong [BOD_DATE - 14, BOD_DATE); Ops khac -> 0, thieu actor -> NULL.
   KHONG rank HD theo offer. Chi rank T gan nhat THEO TUNG HD + Ops.
   duplicate_ranked van khu SAS grain trung truoc khi chon T.
   Gan HD bang CUID + offer + Ops cua BOD1/BOD2; mot call co the gan nhieu HD.
   Do do day la lien ket theo offer, khong phai bang chung call tao HD cu the.
   FIRST_APPLY_CONTRACT giu ten cot cu; hien tung HD, gom ca HD cu cung offer.
   Contract context gom DISTINCT; Step3 van doc toan bo lich su TLS 14 ngay.
   Final  = Step 3 = 1 AND (Step 1 = 1 OR Step 2 = 1)
   ===================================================================== */
WITH params AS (
    SELECT TRUNC(SYSDATE)                       AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)       AS date_from,
           TRUNC(SYSDATE) + 1                   AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14  AS date_from_t0   -- lui 14 ngay de khong mat T0 cua T dau ky
    FROM dual
),

/* 1. Call goc: ky bao cao + 14 ngay lui (cho T0). Chi lay cot can dung. */
call_raw AS (
    SELECT /*+ MATERIALIZE */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid,
        sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE
            WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                THEN 'Personal Callback'
            WHEN sas.type_tls_call = 'OB_Man'
             AND sas.target_object_selected NOT LIKE '%INBOUND%'
             AND sas.interaction_type_key = 3
                THEN 'Manual Outbound'
            ELSE sas.call_type
        END AS call_type
    FROM ap_tls.tb_tls_call_sas sas
    CROSS JOIN params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (   sas.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                              'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
           OR sas.call_type IN ('Inbound', 'Outbound'))
    AND sas.cuid in(    '28923657','163632637')
),

/* 2. Call len dashboard (dieu kien QC07) */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
        COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c
    CROSS JOIN params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. Khu trung grain: chi grain bi trung moi can scoring theo uu tien QC07 */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re
    CROSS JOIN params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX', 'CCX', 'CC_CC', 'ACLX', 'ACLLG', 'XNA', 'SAI', 'ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT d.cuid_num FROM calls_qc d WHERE d.grain_count > 1)
),
duplicate_ranked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
            ORDER BY
                CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END ASC NULLS LAST
        ) AS rn
    FROM calls_qc c
    LEFT JOIN scoring sc ON sc.id_cuid = c.cuid_num
    WHERE c.grain_count > 1
),

/* 4. Chi giu call T (Manual/Personal) sau khi khu trung -> giam manh so dong */
t_calls AS (
    SELECT c.* FROM calls_qc c
    WHERE c.grain_count = 1
      AND c.call_type IN ('Manual Outbound', 'Personal Callback')
    UNION ALL
    SELECT d.call_id, d.resource_role, d.interaction_resource_ordinal, d.call_uuid,
           d.media_server_ixn_guid, d.cuid, d.cuid_num, d.username, d.orig_offer_id,
           d.time_of_call_start, d.time_of_call_end, d.durations, d.channel,
           d.name_camp_call, d.call_type_raw, d.call_type, d.grain_count
    FROM duplicate_ranked d
    WHERE d.rn = 1
      AND d.call_type IN ('Manual Outbound', 'Personal Callback')
),

/* 5. Tat ca HD cua CUID + offer co call T; KHONG rank latest / offer. */
contract AS (
    SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
           x.preprocess_user, x.process_date, x.process_user, 'CLX' AS appl_source
    FROM ap_tls.tb_tls_appl_clx x
    WHERE EXISTS (SELECT 1 FROM t_calls tc
                  WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
    UNION ALL
    SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
           x.preprocess_user, x.process_date, x.process_user, 'CCX'
    FROM ap_tls.tb_tls_appl_ccx x
    WHERE EXISTS (SELECT 1 FROM t_calls tc
                  WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
),

/* 6. Tat ca cap call x HD khop offer + Ops; khong rank de loai HD cu. */
follow_candidates AS (
    SELECT
            s.cuid, s.cuid_num, s.username, s.orig_offer_id, s.call_id,
            s.media_server_ixn_guid, s.call_type, s.time_of_call_start,
            a.cuid            AS contract_cuid,
            a.contract_code, a.appl_source,
            a.preprocess_date AS bod1_date,
            CASE WHEN (a.preprocess_user = s.username AND s.time_of_call_start - a.preprocess_date <= 30)
                   OR (a.process_user    = s.username AND s.time_of_call_start - a.process_date    <= 180)
                 THEN 1 ELSE 0 END AS result_step_2,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN 'BOD2'
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN a.process_date
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN a.preprocess_date END AS bod_date
        FROM t_calls s
        LEFT JOIN contract a
          ON a.cuid          = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         AND (a.preprocess_user = s.username OR a.process_user = s.username)
),
/* Chon T gan nhat RIENG tung CONTRACT_CODE + Ops, khong partition theo offer. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   PARTITION BY f.cuid, f.contract_code, f.username
                   ORDER BY f.time_of_call_start DESC NULLS LAST,
                            f.call_id DESC NULLS LAST,
                            f.appl_source ASC NULLS LAST,
                            f.orig_offer_id ASC NULLS LAST,
                            f.bod_date DESC NULLS LAST,
                            f.bod1_date DESC NULLS LAST,
                            f.media_server_ixn_guid DESC NULLS LAST
               ) AS rn_t
        FROM follow_candidates f
    ) WHERE rn_t = 1
),
/* Context khong phu thuoc ngay T: tinh 1 lan / HD + offer + source + Ops + BOD. */
contract_keys AS (
    SELECT DISTINCT cuid, contract_cuid, contract_code, orig_offer_id,
           appl_source, username, bod1_date, bod_date
    FROM follow_calls
    WHERE contract_code IS NOT NULL
),

/* 7. Gom IB/OB som nhat 1 lan / CUID + Ops; evaluated chi dung neu T0 < T.
   Khong gom theo HD khi co nhieu T: se gan sai T0 sau mot call T cu hon. */
t0 AS (
    SELECT x.cuid, x.username,
           MIN(x.time_of_call_start) AS time_of_call_start_t0
    FROM call_raw x
    WHERE x.call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls t
                  WHERE t.cuid = x.cuid AND t.username = x.username)
    GROUP BY x.cuid, x.username
),

/* 8. Loai call gan thoi diem len BOD (de biet HD tu IB/OB hay Manual/Personal) */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date,
        MIN(c.call_type) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
                c.time_of_call_start DESC NULLS LAST,
                c.call_id DESC NULLS LAST,
                c.call_uuid DESC NULLS LAST
        ) AS contract_call_type
    FROM contract_keys f
    JOIN calls_qc c
      ON c.cuid          = f.cuid
     AND c.username      = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date
),

/* 9. Lich su HD chi cho CUID co T; dung chung cho Step 3 va HD tiep theo.
   Khong loc TLS o day: chi Step 3 duoc thu hep, Next giu logic ban goc. */
appl_hist AS (
    SELECT /*+ MATERIALIZE */ a.cuid, a.contract_code, a.orig_offer_id,
           a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
           a.name_credit_status, 'CLX' AS appl_source
    FROM ap_tls.tb_tls_appl_clx a
    WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
    UNION ALL
    SELECT a.cuid, a.contract_code, a.orig_offer_id,
           a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
           a.name_credit_status, 'CCX'
    FROM ap_tls.tb_tls_appl_ccx a
    WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
),

/* Chi nap BOD events trong bounds cua CUID can kiem tra, ke ca process_date
   gan day cua HD co preprocess_date cu. Khong xet trang thai Reject/Cancel. */
history_bounds AS (
    SELECT contract_cuid, MIN(bod_date) - 14 AS date_from, MAX(bod_date) AS date_to
    FROM contract_keys
    WHERE bod_date IS NOT NULL
    GROUP BY contract_cuid
),
history_bod_events AS (
    SELECT h.cuid, h.orig_offer_id,
           h.preprocess_date AS event_date, h.preprocess_user AS event_user
    FROM appl_hist h
    JOIN history_bounds w ON w.contract_cuid = h.cuid
                         AND h.preprocess_date >= w.date_from
                         AND h.preprocess_date < w.date_to
    UNION ALL
    SELECT h.cuid, h.orig_offer_id, h.process_date, h.process_user
    FROM appl_hist h
    JOIN history_bounds w ON w.contract_cuid = h.cuid
                         AND h.process_date >= w.date_from
                         AND h.process_date < w.date_to
),
tls_history_offers AS (
    /* QC07: call.channel + duration/UUID/campaign; gan HD bang CUID + offer.
       Khong dung process_type MC/PRO de suy ra TLS; khong yeu cau call.username
       = actor BOD vi QC07 khong co dieu kien do khi join contract.
       EXISTS tren offer keys khong lam nhan dong events boi nhieu call.
       CUID SAS la chuoi, CUID CLX/CCX la so nhu cach join contract cua QC07. */
    SELECT k.cuid, k.orig_offer_id
    FROM (SELECT DISTINCT cuid, orig_offer_id FROM history_bod_events) k
    CROSS JOIN params p
    WHERE EXISTS (
        SELECT 1
        FROM ap_tls.tb_tls_call_sas s
        WHERE s.cuid = TO_CHAR(k.cuid)
          AND s.orig_offer_id = k.orig_offer_id
          AND s.time_of_call_start < p.date_to
          AND s.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                            'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
          AND (s.durations > 0
               OR (s.durations = 0 AND s.call_type = 'Inbound' AND s.call_uuid IS NOT NULL)
               OR (s.call_type = 'Outbound' AND s.name_camp_call IS NULL))
    )
),
prior_tls_flags AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod_date,
           MAX(CASE WHEN LOWER(e.event_user) <> LOWER(b.username) THEN 1 ELSE 0 END) AS has_other_ops,
           MAX(CASE WHEN e.event_user IS NULL THEN 1 ELSE 0 END) AS has_unknown_ops
    FROM contract_keys b
    JOIN history_bod_events e ON e.cuid = b.contract_cuid
                            AND e.event_date >= b.bod_date - 14
                            AND e.event_date < b.bod_date
    JOIN tls_history_offers k ON k.cuid = e.cuid AND k.orig_offer_id = e.orig_offer_id
    /* Khong loai chinh HD: BOD1 cua Ops khac van can xet truoc BOD2 hien tai. */
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod_date
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date,
        /* HD lien ke SAU: giu nguyen logic Next cua ban goc */
        MIN(CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                 THEN h.preprocess_date END) AS next_apply_date,
        MIN(h.contract_code) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_contract_raw,
        MIN(h.name_credit_status) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_status_raw
    FROM contract_keys b
    JOIN appl_hist h
      ON h.cuid           = b.contract_cuid
     AND h.contract_code <> b.contract_code
     AND h.preprocess_date > b.bod1_date
     AND h.preprocess_date <= SYSDATE
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date
),

/* 10. Team / SUP */
emp AS (
    SELECT LOWER(username) AS username_lc, team, date_valid_from,
           NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h
    CROSS JOIN params p
    WHERE h.sup_name IS NOT NULL
      AND h.month >= TO_CHAR(p.date_from, 'YYYY-MM')
      AND h.month <= TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
),

/* 11. Cham diem */
evaluated AS (
    SELECT r.*,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
             THEN x.time_of_call_start_t0 END AS time_of_call_start_t0,
        mc.contract_call_type,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_contract_raw END AS next_apply_contract,
        v.next_apply_date,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_status_raw   END AS name_credit_status,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
              AND r.time_of_call_start - x.time_of_call_start_t0 <= 14
             THEN 1 ELSE 0 END AS result_step_1,
        CASE
            WHEN r.contract_code IS NULL                             THEN 0
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')     THEN 1
            WHEN r.bod_date IS NULL                                  THEN 0
            WHEN pf.has_other_ops = 1                                THEN 0
            WHEN pf.has_unknown_ops = 1                              THEN NULL
            ELSE 1
        END AS result_step_3
    FROM follow_calls r
    LEFT JOIN t0 x ON x.cuid = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.username = r.username
                             AND mc.appl_source = r.appl_source AND mc.orig_offer_id = r.orig_offer_id
                             AND mc.bod_date = r.bod_date
    LEFT JOIN hist_context v ON v.cuid = r.cuid AND v.contract_code = r.contract_code AND v.username = r.username
                           AND v.appl_source = r.appl_source AND v.orig_offer_id = r.orig_offer_id
                           AND v.bod1_date = r.bod1_date
    LEFT JOIN prior_tls_flags pf ON pf.cuid = r.cuid AND pf.contract_code = r.contract_code AND pf.username = r.username
                               AND pf.appl_source = r.appl_source AND pf.orig_offer_id = r.orig_offer_id
                               AND pf.bod_date = r.bod_date
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                                   AS call_uuid,
    r.username,
    e.team,
    h.sup_name                                                AS sup,
    r.contract_call_type,
    r.call_type,
    r.time_of_call_start_t0,
    r.time_of_call_start                                      AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                               AS report_date,
    r.time_of_call_start - r.time_of_call_start_t0  AS t_diff_t0,
    r.contract_code                                           AS first_apply_contract,
    r.stage,
    r.bod_date,
    r.time_of_call_start - r.bod_date               AS follow_dates,
    r.next_apply_contract,
    r.next_apply_date,
    r.name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.result_step_3,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                                    AS final_result
FROM evaluated r
LEFT JOIN emp e ON e.username_lc = LOWER(r.username)
               AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to
LEFT JOIN hr  h ON h.op_username = r.username
               AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM');






---------------------
/* =====================================================================
   QC07 FOLLOW TRACKING - BAN TOI UU (Power BI)
   Ky: 1 thang den het hom nay. Giu TAT CA HD khop call/offer/Ops, ke ca HD QC07 an.
   Grain: 1 dong / CUID + CONTRACT_CODE + Ops; chua khop HD thi hien HD NULL.
   T      = Manual Outbound / Personal Callback GAN NHAT / CUID + HD + Ops.
   T0     = Inbound / Outbound SOM NHAT truoc T (cung CUID + Ops), co the NULL
   Step 1 = 1 khi T - T0 <= 14 ngay; > 14 ngay hoac khong co T0 -> 0
   Step 2 = cung Ops: T - BOD1 <= 30 hoac T - BOD2 <= 180; khong chan BOD sau T
   Step 3 = HD tu IB/OB -> 1; con lai xet TAT CA BOD1/BOD2 lien quan TLS
            trong [BOD_DATE - 14, BOD_DATE); Ops khac -> 0, thieu actor -> NULL.
   KHONG rank HD theo offer. Chi rank T gan nhat THEO TUNG HD + Ops.
   duplicate_ranked van khu SAS grain trung truoc khi chon T.
   Gan HD bang CUID + offer + Ops cua BOD1/BOD2; mot call co the gan nhieu HD.
   Do do day la lien ket theo offer, khong phai bang chung call tao HD cu the.
   FIRST_APPLY_CONTRACT giu ten cot cu; hien tung HD, gom ca HD cu cung offer.
   Contract context gom DISTINCT; Step3 van doc toan bo lich su TLS 14 ngay.
   Cua so HD: chi gan HD co BOD1 hoac BOD2 trong [T - contract_lookback_days, date_to).
   QC07_VISIBLE = 1: HD dang hien tren QC07 (rnk = 1 trong ky); 0 = HD QC07 an.
   Final  = Step 3 = 1 AND (Step 1 = 1 OR Step 2 = 1)
   ===================================================================== */
WITH params AS (
    SELECT TRUNC(SYSDATE)                       AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)       AS date_from,
           TRUNC(SYSDATE) + 1                   AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14  AS date_from_t0,  -- lui 14 ngay de khong mat T0 cua T dau ky
           90                                   AS contract_lookback_days  -- 30 = 1 thang, 90 = 3 thang truoc T
    FROM dual
),

/* 1. Call goc: ky bao cao + 14 ngay lui (cho T0). Chi lay cot can dung. */
call_raw AS (
    SELECT /*+ MATERIALIZE */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid,
        sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE
            WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                THEN 'Personal Callback'
            WHEN sas.type_tls_call = 'OB_Man'
             AND sas.target_object_selected NOT LIKE '%INBOUND%'
             AND sas.interaction_type_key = 3
                THEN 'Manual Outbound'
            ELSE sas.call_type
        END AS call_type
    FROM ap_tls.tb_tls_call_sas sas
    CROSS JOIN params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (   sas.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                              'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
           OR sas.call_type IN ('Inbound', 'Outbound'))
      AND sas.cuid IN ('7983363', '7395011')   -- TEST: xoa dong nay khi chay full
),

/* 2. Call len dashboard (dieu kien QC07) */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
        COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c
    CROSS JOIN params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. Khu trung grain: chi grain bi trung moi can scoring theo uu tien QC07 */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re
    CROSS JOIN params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX', 'CCX', 'CC_CC', 'ACLX', 'ACLLG', 'XNA', 'SAI', 'ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT d.cuid_num FROM calls_qc d WHERE d.grain_count > 1)
),
duplicate_ranked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
            ORDER BY
                CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END ASC NULLS LAST
        ) AS rn
    FROM calls_qc c
    LEFT JOIN scoring sc ON sc.id_cuid = c.cuid_num
    WHERE c.grain_count > 1
),

/* 4. Chi giu call T (Manual/Personal) sau khi khu trung -> giam manh so dong */
t_calls AS (
    SELECT c.* FROM calls_qc c
    WHERE c.grain_count = 1
      AND c.call_type IN ('Manual Outbound', 'Personal Callback')
    UNION ALL
    SELECT d.call_id, d.resource_role, d.interaction_resource_ordinal, d.call_uuid,
           d.media_server_ixn_guid, d.cuid, d.cuid_num, d.username, d.orig_offer_id,
           d.time_of_call_start, d.time_of_call_end, d.durations, d.channel,
           d.name_camp_call, d.call_type_raw, d.call_type, d.grain_count
    FROM duplicate_ranked d
    WHERE d.rn = 1
      AND d.call_type IN ('Manual Outbound', 'Personal Callback')
),

/* 5. Tat ca HD cua CUID + offer co call T (ca HD QC07 an).
   QC07_VISIBLE mo phong cach QC07 chon HD: trong ky, rnk = 1 theo nguon x CUID x offer. */
contract AS (
    SELECT u.*,
           CASE WHEN u.preprocess_date >= p.date_from
                 AND ROW_NUMBER() OVER (
                         PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                         ORDER BY CASE WHEN u.preprocess_date >= p.date_from THEN 0 ELSE 1 END,
                                  u.preprocess_date DESC) = 1
                THEN 1 ELSE 0 END AS qc07_visible
    FROM (
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx x
        WHERE EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
        UNION ALL
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CCX'
        FROM ap_tls.tb_tls_appl_ccx x
        WHERE EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
    ) u
    CROSS JOIN params p
),

/* 6. Tat ca cap call x HD khop offer + Ops; khong rank de loai HD cu. */
follow_candidates AS (
    SELECT
            s.cuid, s.cuid_num, s.username, s.orig_offer_id, s.call_id,
            s.media_server_ixn_guid, s.call_type, s.time_of_call_start,
            a.cuid            AS contract_cuid,
            a.contract_code, a.appl_source,
            a.qc07_visible,
            a.name_credit_status AS contract_status,
            a.preprocess_date AS bod1_date,
            a.preprocess_user AS bod1_user,
            a.process_date    AS bod2_date,
            a.process_user    AS bod2_user,
            CASE WHEN (a.preprocess_user = s.username AND s.time_of_call_start - a.preprocess_date <= 30)
                   OR (a.process_user    = s.username AND s.time_of_call_start - a.process_date    <= 180)
                 THEN 1 ELSE 0 END AS result_step_2,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN 'BOD2'
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN a.process_date
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN a.preprocess_date END AS bod_date
        FROM t_calls s
        CROSS JOIN params p
        LEFT JOIN contract a
          ON a.cuid          = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         AND (a.preprocess_user = s.username OR a.process_user = s.username)
         /* chi lay HD co BOD trong cua so 1/3 thang truoc T (khong chan BOD sau T) */
         AND (   a.preprocess_date >= s.time_of_call_start - p.contract_lookback_days
              OR a.process_date    >= s.time_of_call_start - p.contract_lookback_days)
),
/* Chon T gan nhat RIENG tung CONTRACT_CODE + Ops, khong partition theo offer. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   PARTITION BY f.cuid, f.contract_code, f.username
                   ORDER BY f.time_of_call_start DESC NULLS LAST,
                            f.call_id DESC NULLS LAST,
                            f.appl_source ASC NULLS LAST,
                            f.orig_offer_id ASC NULLS LAST,
                            f.bod_date DESC NULLS LAST,
                            f.bod1_date DESC NULLS LAST,
                            f.media_server_ixn_guid DESC NULLS LAST
               ) AS rn_t
        FROM follow_candidates f
    ) WHERE rn_t = 1
),
/* Context khong phu thuoc ngay T: tinh 1 lan / HD + offer + source + Ops + BOD. */
contract_keys AS (
    SELECT DISTINCT cuid, contract_cuid, contract_code, orig_offer_id,
           appl_source, username, bod1_date, bod_date
    FROM follow_calls
    WHERE contract_code IS NOT NULL
),

/* 7. Gom IB/OB som nhat 1 lan / CUID + Ops; evaluated chi dung neu T0 < T.
   Khong gom theo HD khi co nhieu T: se gan sai T0 sau mot call T cu hon. */
t0 AS (
    SELECT x.cuid, x.username,
           MIN(x.time_of_call_start) AS time_of_call_start_t0
    FROM call_raw x
    WHERE x.call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls t
                  WHERE t.cuid = x.cuid AND t.username = x.username)
    GROUP BY x.cuid, x.username
),

/* 8. Loai call gan thoi diem len BOD (de biet HD tu IB/OB hay Manual/Personal) */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date,
        MIN(c.call_type) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
                c.time_of_call_start DESC NULLS LAST,
                c.call_id DESC NULLS LAST,
                c.call_uuid DESC NULLS LAST
        ) AS contract_call_type
    FROM contract_keys f
    JOIN calls_qc c
      ON c.cuid          = f.cuid
     AND c.username      = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date
),

/* 9. Lich su HD chi cho CUID co T; dung chung cho Step 3 va HD tiep theo.
   Khong loc TLS o day: chi Step 3 duoc thu hep, Next giu logic ban goc. */
appl_hist AS (
    SELECT /*+ MATERIALIZE */ a.cuid, a.contract_code, a.orig_offer_id,
           a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
           a.name_credit_status, 'CLX' AS appl_source
    FROM ap_tls.tb_tls_appl_clx a
    WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
    UNION ALL
    SELECT a.cuid, a.contract_code, a.orig_offer_id,
           a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
           a.name_credit_status, 'CCX'
    FROM ap_tls.tb_tls_appl_ccx a
    WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
),

/* Chi nap BOD events trong bounds cua CUID can kiem tra, ke ca process_date
   gan day cua HD co preprocess_date cu. Khong xet trang thai Reject/Cancel. */
history_bounds AS (
    SELECT contract_cuid, MIN(bod_date) - 14 AS date_from, MAX(bod_date) AS date_to
    FROM contract_keys
    WHERE bod_date IS NOT NULL
    GROUP BY contract_cuid
),
history_bod_events AS (
    SELECT h.cuid, h.orig_offer_id,
           h.preprocess_date AS event_date, h.preprocess_user AS event_user
    FROM appl_hist h
    JOIN history_bounds w ON w.contract_cuid = h.cuid
                         AND h.preprocess_date >= w.date_from
                         AND h.preprocess_date < w.date_to
    UNION ALL
    SELECT h.cuid, h.orig_offer_id, h.process_date, h.process_user
    FROM appl_hist h
    JOIN history_bounds w ON w.contract_cuid = h.cuid
                         AND h.process_date >= w.date_from
                         AND h.process_date < w.date_to
),
tls_history_offers AS (
    /* QC07: call.channel + duration/UUID/campaign; gan HD bang CUID + offer.
       Khong dung process_type MC/PRO de suy ra TLS; khong yeu cau call.username
       = actor BOD vi QC07 khong co dieu kien do khi join contract.
       EXISTS tren offer keys khong lam nhan dong events boi nhieu call.
       CUID SAS la chuoi, CUID CLX/CCX la so nhu cach join contract cua QC07. */
    SELECT k.cuid, k.orig_offer_id
    FROM (SELECT DISTINCT cuid, orig_offer_id FROM history_bod_events) k
    CROSS JOIN params p
    WHERE EXISTS (
        SELECT 1
        FROM ap_tls.tb_tls_call_sas s
        WHERE s.cuid = TO_CHAR(k.cuid)
          AND s.orig_offer_id = k.orig_offer_id
          AND s.time_of_call_start < p.date_to
          AND s.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                            'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
          AND (s.durations > 0
               OR (s.durations = 0 AND s.call_type = 'Inbound' AND s.call_uuid IS NOT NULL)
               OR (s.call_type = 'Outbound' AND s.name_camp_call IS NULL))
    )
),
prior_tls_flags AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod_date,
           MAX(CASE WHEN LOWER(e.event_user) <> LOWER(b.username) THEN 1 ELSE 0 END) AS has_other_ops,
           MAX(CASE WHEN e.event_user IS NULL THEN 1 ELSE 0 END) AS has_unknown_ops
    FROM contract_keys b
    JOIN history_bod_events e ON e.cuid = b.contract_cuid
                            AND e.event_date >= b.bod_date - 14
                            AND e.event_date < b.bod_date
    JOIN tls_history_offers k ON k.cuid = e.cuid AND k.orig_offer_id = e.orig_offer_id
    /* Khong loai chinh HD: BOD1 cua Ops khac van can xet truoc BOD2 hien tai. */
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod_date
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date,
        /* HD lien ke SAU: giu nguyen logic Next cua ban goc */
        MIN(CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                 THEN h.preprocess_date END) AS next_apply_date,
        MIN(h.contract_code) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_contract_raw,
        MIN(h.name_credit_status) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_status_raw
    FROM contract_keys b
    JOIN appl_hist h
      ON h.cuid           = b.contract_cuid
     AND h.contract_code <> b.contract_code
     AND h.preprocess_date > b.bod1_date
     AND h.preprocess_date <= SYSDATE
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date
),

/* 10. Team / SUP */
emp AS (
    SELECT LOWER(username) AS username_lc, team, date_valid_from,
           NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h
    CROSS JOIN params p
    WHERE h.sup_name IS NOT NULL
      AND h.month >= TO_CHAR(p.date_from, 'YYYY-MM')
      AND h.month <= TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
),

/* 11. Cham diem */
evaluated AS (
    SELECT r.*,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
             THEN x.time_of_call_start_t0 END AS time_of_call_start_t0,
        mc.contract_call_type,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_contract_raw END AS next_apply_contract,
        v.next_apply_date,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_status_raw   END AS name_credit_status,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
              AND r.time_of_call_start - x.time_of_call_start_t0 <= 14
             THEN 1 ELSE 0 END AS result_step_1,
        CASE
            WHEN r.contract_code IS NULL                             THEN 0
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')     THEN 1
            WHEN r.bod_date IS NULL                                  THEN 0
            WHEN pf.has_other_ops = 1                                THEN 0
            WHEN pf.has_unknown_ops = 1                              THEN NULL
            ELSE 1
        END AS result_step_3
    FROM follow_calls r
    LEFT JOIN t0 x ON x.cuid = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.username = r.username
                             AND mc.appl_source = r.appl_source AND mc.orig_offer_id = r.orig_offer_id
                             AND mc.bod_date = r.bod_date
    LEFT JOIN hist_context v ON v.cuid = r.cuid AND v.contract_code = r.contract_code AND v.username = r.username
                           AND v.appl_source = r.appl_source AND v.orig_offer_id = r.orig_offer_id
                           AND v.bod1_date = r.bod1_date
    LEFT JOIN prior_tls_flags pf ON pf.cuid = r.cuid AND pf.contract_code = r.contract_code AND pf.username = r.username
                               AND pf.appl_source = r.appl_source AND pf.orig_offer_id = r.orig_offer_id
                               AND pf.bod_date = r.bod_date
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                                   AS call_uuid,
    r.username,
    e.team,
    h.sup_name                                                AS sup,
    r.contract_call_type,
    r.call_type,
    r.time_of_call_start_t0,
    r.time_of_call_start                                      AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                               AS report_date,
    ROUND(r.time_of_call_start - r.time_of_call_start_t0, 2)  AS t_diff_t0,
    r.contract_code                                           AS first_apply_contract,
    r.appl_source,
    r.qc07_visible,                                           -- 1 = HD hien tren QC07; 0 = HD QC07 an
    r.contract_status,
    r.bod1_date,
    r.bod1_user,
    r.bod2_date,
    r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)               AS follow_dates,
    r.next_apply_contract,
    r.next_apply_date,
    r.name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.result_step_3,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                                    AS final_result
FROM evaluated r
LEFT JOIN emp e ON e.username_lc = LOWER(r.username)
               AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to
LEFT JOIN hr  h ON h.op_username = r.username
               AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM');







---------------------












/* =====================================================================
   QC07 FOLLOW TRACKING - BAN TOI UU (Power BI)
   Ky: 1 thang den het hom nay. Giu TAT CA HD khop call/offer/Ops, ke ca HD QC07 an.
   Grain: 1 dong / CUID + CONTRACT_CODE + Ops; chua khop HD thi hien HD NULL.
   T      = Manual Outbound / Personal Callback GAN NHAT / CUID + HD + Ops.
   T0     = Inbound / Outbound SOM NHAT truoc T (cung CUID + Ops), co the NULL
   Step 1 = 1 khi T - T0 <= 14 ngay; > 14 ngay hoac khong co T0 -> 0
   Step 2 = cung Ops: T - BOD1 <= 30 hoac T - BOD2 <= 180; khong chan BOD sau T
   Step 3 = HD tu IB/OB -> 1; Ops khong len BOD1 -> 0;
            con lai xet HD LIEN KE TRUOC (theo ngay BOD1, cung CUID):
            khong co / cung Ops -> 1; Ops khac va cach <= 14 ngay -> 0; > 14 ngay -> 1.
   MAP HD: theo CUID + offer (giong QC07), KHONG bat buoc cung Ops.
            MAP_TYPE = 'Ops len HD' hoac 'Ops khac len HD' (Step 2/3 = 0).
   KHONG rank HD theo offer. Chi rank T gan nhat THEO TUNG HD + Ops.
   duplicate_ranked van khu SAS grain trung truoc khi chon T.
   Gan HD bang CUID + offer + Ops cua BOD1/BOD2; mot call co the gan nhieu HD.
   Do do day la lien ket theo offer, khong phai bang chung call tao HD cu the.
   FIRST_APPLY_CONTRACT giu ten cot cu; hien tung HD, gom ca HD cu cung offer.
   Contract context gom DISTINCT; Step3 van doc toan bo lich su TLS 14 ngay.
   Cua so HD: chi gan HD co BOD1 hoac BOD2 trong [T - contract_lookback_days, date_to).
   QC07_VISIBLE = 1: HD dang hien tren QC07 (rnk = 1 trong ky); 0 = HD QC07 an.
   Final  = Step 3 = 1 AND (Step 1 = 1 OR Step 2 = 1)
   ===================================================================== */
WITH params AS (
    SELECT TRUNC(SYSDATE)                       AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)       AS date_from,
           TRUNC(SYSDATE) + 1                   AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14  AS date_from_t0,  -- lui 14 ngay de khong mat T0 cua T dau ky
           90                                   AS contract_lookback_days  -- 30 = 1 thang, 90 = 3 thang truoc T
    FROM dual
),

/* 1. Call goc: ky bao cao + 14 ngay lui (cho T0). Chi lay cot can dung. */
call_raw AS (
    SELECT /*+ MATERIALIZE */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid,
        sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE
            WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                THEN 'Personal Callback'
            WHEN sas.type_tls_call = 'OB_Man'
             AND sas.target_object_selected NOT LIKE '%INBOUND%'
             AND sas.interaction_type_key = 3
                THEN 'Manual Outbound'
            ELSE sas.call_type
        END AS call_type
    FROM ap_tls.tb_tls_call_sas sas
    CROSS JOIN params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (   sas.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                              'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
           OR sas.call_type IN ('Inbound', 'Outbound'))
      AND sas.cuid IN ('7983363', '7395011')   -- TEST: xoa dong nay khi chay full
),

/* 2. Call len dashboard (dieu kien QC07) */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
        COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c
    CROSS JOIN params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. Khu trung grain: chi grain bi trung moi can scoring theo uu tien QC07 */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re
    CROSS JOIN params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX', 'CCX', 'CC_CC', 'ACLX', 'ACLLG', 'XNA', 'SAI', 'ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT d.cuid_num FROM calls_qc d WHERE d.grain_count > 1)
),
duplicate_ranked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
            ORDER BY
                CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END ASC NULLS LAST
        ) AS rn
    FROM calls_qc c
    LEFT JOIN scoring sc ON sc.id_cuid = c.cuid_num
    WHERE c.grain_count > 1
),

/* 4. Chi giu call T (Manual/Personal) sau khi khu trung -> giam manh so dong */
t_calls AS (
    SELECT c.* FROM calls_qc c
    WHERE c.grain_count = 1
      AND c.call_type IN ('Manual Outbound', 'Personal Callback')
    UNION ALL
    SELECT d.call_id, d.resource_role, d.interaction_resource_ordinal, d.call_uuid,
           d.media_server_ixn_guid, d.cuid, d.cuid_num, d.username, d.orig_offer_id,
           d.time_of_call_start, d.time_of_call_end, d.durations, d.channel,
           d.name_camp_call, d.call_type_raw, d.call_type, d.grain_count
    FROM duplicate_ranked d
    WHERE d.rn = 1
      AND d.call_type IN ('Manual Outbound', 'Personal Callback')
),

/* 5. Tat ca HD cua CUID + offer co call T (ca HD QC07 an).
   QC07_VISIBLE mo phong cach QC07 chon HD: trong ky, rnk = 1 theo nguon x CUID x offer. */
contract AS (
    SELECT u.*,
           CASE WHEN u.preprocess_date >= p.date_from
                 AND ROW_NUMBER() OVER (
                         PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                         ORDER BY CASE WHEN u.preprocess_date >= p.date_from THEN 0 ELSE 1 END,
                                  u.preprocess_date DESC) = 1
                THEN 1 ELSE 0 END AS qc07_visible
    FROM (
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx x
        WHERE EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
        UNION ALL
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CCX'
        FROM ap_tls.tb_tls_appl_ccx x
        WHERE EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
    ) u
    CROSS JOIN params p
),

/* 6. Tat ca cap call x HD khop offer + Ops; khong rank de loai HD cu. */
follow_candidates AS (
    SELECT
            s.cuid, s.cuid_num, s.username, s.orig_offer_id, s.call_id,
            s.media_server_ixn_guid, s.call_type, s.time_of_call_start,
            a.cuid            AS contract_cuid,
            a.contract_code, a.appl_source,
            a.qc07_visible,
            CASE WHEN a.contract_code IS NULL THEN NULL
                 WHEN LOWER(a.preprocess_user) = LOWER(s.username)
                   OR LOWER(a.process_user)    = LOWER(s.username) THEN 'Ops len HD'
                 ELSE 'Ops khac len HD' END AS map_type,
            NVL(a.process_date, a.preprocess_date) AS contract_bod_date,
            a.name_credit_status AS contract_status,
            a.preprocess_date AS bod1_date,
            a.preprocess_user AS bod1_user,
            a.process_date    AS bod2_date,
            a.process_user    AS bod2_user,
            CASE WHEN (a.preprocess_user = s.username AND s.time_of_call_start - a.preprocess_date <= 30)
                   OR (a.process_user    = s.username AND s.time_of_call_start - a.process_date    <= 180)
                 THEN 1 ELSE 0 END AS result_step_2,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN 'BOD2'
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN a.process_date
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN a.preprocess_date END AS bod_date
        FROM t_calls s
        CROSS JOIN params p
        LEFT JOIN contract a
          ON a.cuid          = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         /* KHONG bat buoc cung Ops: map theo CUID + offer nhu QC07 */
         /* chi lay HD co BOD trong cua so 1/3 thang truoc T (khong chan BOD sau T) */
         AND (   a.preprocess_date >= s.time_of_call_start - p.contract_lookback_days
              OR a.process_date    >= s.time_of_call_start - p.contract_lookback_days)
),
/* Chon T gan nhat RIENG tung CONTRACT_CODE + Ops, khong partition theo offer. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   PARTITION BY f.cuid, f.contract_code, f.username
                   ORDER BY f.time_of_call_start DESC NULLS LAST,
                            f.call_id DESC NULLS LAST,
                            f.appl_source ASC NULLS LAST,
                            f.orig_offer_id ASC NULLS LAST,
                            f.bod_date DESC NULLS LAST,
                            f.bod1_date DESC NULLS LAST,
                            f.media_server_ixn_guid DESC NULLS LAST
               ) AS rn_t
        FROM follow_candidates f
    ) WHERE rn_t = 1
),
/* Context khong phu thuoc ngay T: tinh 1 lan / HD + offer + source + Ops + BOD. */
contract_keys AS (
    SELECT DISTINCT cuid, contract_cuid, contract_code, orig_offer_id,
           appl_source, username, bod1_date, bod_date
    FROM follow_calls
    WHERE contract_code IS NOT NULL
),

/* 7. Gom IB/OB som nhat 1 lan / CUID + Ops; evaluated chi dung neu T0 < T.
   Khong gom theo HD khi co nhieu T: se gan sai T0 sau mot call T cu hon. */
t0 AS (
    SELECT x.cuid, x.username,
           MIN(x.time_of_call_start) AS time_of_call_start_t0
    FROM call_raw x
    WHERE x.call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls t
                  WHERE t.cuid = x.cuid AND t.username = x.username)
    GROUP BY x.cuid, x.username
),

/* 8. Loai call gan thoi diem len BOD (de biet HD tu IB/OB hay Manual/Personal) */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date,
        MIN(c.call_type) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
                c.time_of_call_start DESC NULLS LAST,
                c.call_id DESC NULLS LAST,
                c.call_uuid DESC NULLS LAST
        ) AS contract_call_type
    FROM contract_keys f
    JOIN calls_qc c
      ON c.cuid          = f.cuid
     AND c.username      = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date
),

/* 9. Lich su HD chi cho CUID co T; dung chung cho Step 3 va HD tiep theo.
   Khong loc TLS o day: chi Step 3 duoc thu hep, Next giu logic ban goc. */
appl_hist AS (
    SELECT /*+ MATERIALIZE */ a.cuid, a.contract_code, a.orig_offer_id,
           a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
           a.name_credit_status, 'CLX' AS appl_source
    FROM ap_tls.tb_tls_appl_clx a
    WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
    UNION ALL
    SELECT a.cuid, a.contract_code, a.orig_offer_id,
           a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
           a.name_credit_status, 'CCX'
    FROM ap_tls.tb_tls_appl_ccx a
    WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
),

hist_context AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date,
        /* HD lien ke TRUOC (theo ngay BOD1, moi offer, moi kenh) */
        MAX(CASE WHEN h.preprocess_date < b.bod1_date THEN h.preprocess_date END) AS prev_bod1_date,
        MAX(h.contract_code) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_contract_raw,
        MAX(h.preprocess_user) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_bod1_user_raw,
        MAX(h.name_credit_status) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_status_raw,
        /* HD lien ke SAU: giu nguyen logic Next cua ban goc */
        MIN(CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                 THEN h.preprocess_date END) AS next_apply_date,
        MIN(h.contract_code) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_contract_raw,
        MIN(h.name_credit_status) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_status_raw
    FROM contract_keys b
    JOIN appl_hist h
      ON h.cuid           = b.contract_cuid
     AND h.contract_code <> b.contract_code
     AND (    h.preprocess_date < b.bod1_date
          OR (h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE))
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date
),

/* 10. Team / SUP */
emp AS (
    SELECT LOWER(username) AS username_lc, team, date_valid_from,
           NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h
    CROSS JOIN params p
    WHERE h.sup_name IS NOT NULL
      AND h.month >= TO_CHAR(p.date_from, 'YYYY-MM')
      AND h.month <= TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
),

/* 11. Cham diem */
evaluated AS (
    SELECT r.*,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
             THEN x.time_of_call_start_t0 END AS time_of_call_start_t0,
        mc.contract_call_type,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_contract_raw END AS next_apply_contract,
        v.next_apply_date,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_status_raw   END AS name_credit_status,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
              AND r.time_of_call_start - x.time_of_call_start_t0 <= 14
             THEN 1 ELSE 0 END AS result_step_1,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_contract_raw  END AS prev_contract,
        v.prev_bod1_date,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_bod1_user_raw END AS prev_bod1_user,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_status_raw    END AS prev_credit_status,
        CASE
            WHEN r.contract_code IS NULL                                          THEN 0
            WHEN r.map_type = 'Ops khac len HD'                                   THEN 0
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')                  THEN 1
            WHEN NVL(LOWER(r.bod1_user), '#') <> LOWER(r.username)                 THEN 0
            WHEN v.prev_bod1_date IS NULL                                         THEN 1
            WHEN LOWER(v.prev_bod1_user_raw) = LOWER(r.username)                  THEN 1
            WHEN r.bod1_date - v.prev_bod1_date <= 14                             THEN 0
            ELSE 1
        END AS result_step_3,
        CASE
            WHEN r.contract_code IS NULL
                THEN 'Khong co HD trong cua so'
            WHEN r.map_type = 'Ops khac len HD'
                THEN 'HD do ' || NVL(r.bod1_user, 'N/A') || '/' || NVL(r.bod2_user, 'N/A') || ' len, khong phai Ops nay'
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')
                THEN 'HD tu ' || mc.contract_call_type || ' -> khong xet 14 ngay'
            WHEN NVL(LOWER(r.bod1_user), '#') <> LOWER(r.username)
                THEN 'Ops khong len BOD1 (BOD1 boi ' || NVL(r.bod1_user, 'N/A') || ')'
            WHEN v.prev_bod1_date IS NULL
                THEN 'Khong co HD truoc'
            WHEN LOWER(v.prev_bod1_user_raw) = LOWER(r.username)
                THEN 'HD truoc ' || v.prev_contract_raw || ' cung Ops'
            WHEN r.bod1_date - v.prev_bod1_date <= 14
                THEN 'HD truoc ' || v.prev_contract_raw || ' boi ' || NVL(v.prev_bod1_user_raw, 'N/A')
                     || ' cach ' || TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay <= 14'
            ELSE 'HD truoc ' || v.prev_contract_raw || ' boi Ops khac, cach '
                 || TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay > 14'
        END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0 x ON x.cuid = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.username = r.username
                             AND mc.appl_source = r.appl_source AND mc.orig_offer_id = r.orig_offer_id
                             AND mc.bod_date = r.bod_date
    LEFT JOIN hist_context v ON v.cuid = r.cuid AND v.contract_code = r.contract_code AND v.username = r.username
                           AND v.appl_source = r.appl_source AND v.orig_offer_id = r.orig_offer_id
                           AND v.bod1_date = r.bod1_date
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                                   AS call_uuid,
    r.username,
    e.team,
    h.sup_name                                                AS sup,
    r.contract_call_type,
    r.call_type,
    r.time_of_call_start_t0,
    r.time_of_call_start                                      AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                               AS report_date,
    ROUND(r.time_of_call_start - r.time_of_call_start_t0, 2)  AS t_diff_t0,
    r.contract_code                                           AS first_apply_contract,
    r.appl_source,
    r.qc07_visible,                                           -- 1 = HD hien tren QC07; 0 = HD QC07 an
    r.map_type,
    r.contract_bod_date,
    r.contract_status,
    r.bod1_date,
    r.bod1_user,
    r.bod2_date,
    r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)               AS follow_dates,
    r.next_apply_contract,
    r.next_apply_date,
    r.name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract,
    r.prev_bod1_date,
    r.prev_bod1_user,
    r.prev_credit_status,
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                                    AS final_result
FROM evaluated r
LEFT JOIN emp e ON e.username_lc = LOWER(r.username)
               AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to
LEFT JOIN hr  h ON h.op_username = r.username
               AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM')
order by r.cuid
;












--------------------------------------------------------------------------------
/* =====================================================================
   QC07 FOLLOW TRACKING - BAN TOI UU (Power BI)
   Ky: 1 thang den het hom nay. Giu TAT CA HD khop call/offer/Ops, ke ca HD QC07 an.
   Grain: 1 dong / CUID + CONTRACT_CODE + Ops; chua khop HD thi hien HD NULL.
   T      = Manual Outbound / Personal Callback GAN NHAT / CUID + HD + Ops.
   T0     = Inbound / Outbound SOM NHAT truoc T (cung CUID + Ops), co the NULL
   Step 1 = 1 khi T - T0 <= 14 ngay; > 14 ngay hoac khong co T0 -> 0
   Step 2 = cung Ops: T - BOD1 <= 30 hoac T - BOD2 <= 180; khong chan BOD sau T
   Step 3 = HD tu IB/OB -> 1; Ops khong len BOD1 -> 0;
            con lai xet HD LIEN KE TRUOC (theo ngay BOD1, cung CUID):
            khong co / cung Ops -> 1; Ops khac va cach <= 14 ngay -> 0; > 14 ngay -> 1.
   MAP HD: CUID + offer + chinh Ops len BOD1/BOD2 (ke ca HD QC07 an, qc07_visible = 0).
            Ops goi T ma khong len HD nao -> 1 dong, HD = NULL.
            Step 3 chi xet HD LIEN KE TRUOC trong so HD HIEN TREN DASHBOARD QC07
            (offer co call QC07, rnk = 1 theo nguon x CUID x offer). HD an -> bo qua.
   KHONG rank HD theo offer. Chi rank T gan nhat THEO TUNG HD + Ops.
   duplicate_ranked van khu SAS grain trung truoc khi chon T.
   Gan HD bang CUID + offer + Ops cua BOD1/BOD2; mot call co the gan nhieu HD.
   Do do day la lien ket theo offer, khong phai bang chung call tao HD cu the.
   FIRST_APPLY_CONTRACT giu ten cot cu; hien tung HD, gom ca HD cu cung offer.
   Contract context gom DISTINCT; Step3 van doc toan bo lich su TLS 14 ngay.
   Cua so HD: chi gan HD co BOD1 hoac BOD2 trong [T - contract_lookback_days, date_to).
   QC07_VISIBLE = 1: HD dang hien tren QC07 (rnk = 1 trong ky); 0 = HD QC07 an.
   Final  = Step 3 = 1 AND (Step 1 = 1 OR Step 2 = 1)
   ===================================================================== */
WITH params AS (
    SELECT TRUNC(SYSDATE)                       AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)       AS date_from,
           TRUNC(SYSDATE) + 1                   AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14  AS date_from_t0,  -- lui 14 ngay de khong mat T0 cua T dau ky
           90                                   AS contract_lookback_days  -- 30 = 1 thang, 90 = 3 thang truoc T
    FROM dual
),

/* 1. Call goc: ky bao cao + 14 ngay lui (cho T0). Chi lay cot can dung. */
call_raw AS (
    SELECT /*+ MATERIALIZE */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid,
        sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE
            WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                THEN 'Personal Callback'
            WHEN sas.type_tls_call = 'OB_Man'
             AND sas.target_object_selected NOT LIKE '%INBOUND%'
             AND sas.interaction_type_key = 3
                THEN 'Manual Outbound'
            ELSE sas.call_type
        END AS call_type
    FROM ap_tls.tb_tls_call_sas sas
    CROSS JOIN params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (   sas.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                              'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
           OR sas.call_type IN ('Inbound', 'Outbound'))
--      AND sas.cuid IN ('7983363', '7395011')   -- TEST: xoa dong nay khi chay full
),

/* 2. Call len dashboard (dieu kien QC07) */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
        COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c
    CROSS JOIN params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. Khu trung grain: chi grain bi trung moi can scoring theo uu tien QC07 */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re
    CROSS JOIN params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX', 'CCX', 'CC_CC', 'ACLX', 'ACLLG', 'XNA', 'SAI', 'ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT d.cuid_num FROM calls_qc d WHERE d.grain_count > 1)
),
duplicate_ranked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
            ORDER BY
                CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END ASC NULLS LAST
        ) AS rn
    FROM calls_qc c
    LEFT JOIN scoring sc ON sc.id_cuid = c.cuid_num
    WHERE c.grain_count > 1
),

/* 4. Chi giu call T (Manual/Personal) sau khi khu trung -> giam manh so dong */
t_calls AS (
    SELECT c.* FROM calls_qc c
    WHERE c.grain_count = 1
      AND c.call_type IN ('Manual Outbound', 'Personal Callback')
    UNION ALL
    SELECT d.call_id, d.resource_role, d.interaction_resource_ordinal, d.call_uuid,
           d.media_server_ixn_guid, d.cuid, d.cuid_num, d.username, d.orig_offer_id,
           d.time_of_call_start, d.time_of_call_end, d.durations, d.channel,
           d.name_camp_call, d.call_type_raw, d.call_type, d.grain_count
    FROM duplicate_ranked d
    WHERE d.rn = 1
      AND d.call_type IN ('Manual Outbound', 'Personal Callback')
),

/* 5. Tat ca HD cua CUID + offer co call T (ca HD QC07 an).
   QC07_VISIBLE mo phong cach QC07 chon HD: trong ky, rnk = 1 theo nguon x CUID x offer. */
contract AS (
    SELECT u.*,
           CASE WHEN u.preprocess_date >= p.date_from
                 AND ROW_NUMBER() OVER (
                         PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                         ORDER BY CASE WHEN u.preprocess_date >= p.date_from THEN 0 ELSE 1 END,
                                  u.preprocess_date DESC) = 1
                THEN 1 ELSE 0 END AS qc07_visible
    FROM (
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx x
        WHERE EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
        UNION ALL
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CCX'
        FROM ap_tls.tb_tls_appl_ccx x
        WHERE EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid AND tc.orig_offer_id = x.orig_offer_id)
    ) u
    CROSS JOIN params p
),

/* 6. Tat ca cap call x HD khop offer + Ops; khong rank de loai HD cu. */
follow_candidates AS (
    SELECT
            s.cuid, s.cuid_num, s.username, s.orig_offer_id, s.call_id,
            s.media_server_ixn_guid, s.call_type, s.time_of_call_start,
            a.cuid            AS contract_cuid,
            a.contract_code, a.appl_source,
            a.qc07_visible,
            CASE WHEN a.contract_code IS NULL THEN NULL
                 WHEN LOWER(a.preprocess_user) = LOWER(s.username)
                   OR LOWER(a.process_user)    = LOWER(s.username) THEN 'Ops len HD'
                 ELSE 'Ops khac len HD' END AS map_type,
            NVL(a.process_date, a.preprocess_date) AS contract_bod_date,
            a.name_credit_status AS contract_status,
            a.preprocess_date AS bod1_date,
            a.preprocess_user AS bod1_user,
            a.process_date    AS bod2_date,
            a.process_user    AS bod2_user,
            CASE WHEN (a.preprocess_user = s.username AND s.time_of_call_start - a.preprocess_date <= 30)
                   OR (a.process_user    = s.username AND s.time_of_call_start - a.process_date    <= 180)
                 THEN 1 ELSE 0 END AS result_step_2,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN 'BOD2'
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN a.process_date
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN a.preprocess_date END AS bod_date
        FROM t_calls s
        CROSS JOIN params p
        JOIN contract a
          ON a.cuid          = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         /* Chi gan HD ma CHINH Ops do len BOD1/BOD2 (ke ca HD QC07 an).
            HD cua Ops khac / user he thong KHONG thanh dong rieng, nhung van
            duoc Step 3 xet qua lich su appl_hist (cot prev_contract). */
         AND (LOWER(a.preprocess_user) = LOWER(s.username) OR LOWER(a.process_user) = LOWER(s.username))
         /* chi lay HD co BOD trong cua so 1/3 thang truoc T (khong chan BOD sau T) */
         AND (   a.preprocess_date >= s.time_of_call_start - p.contract_lookback_days
              OR a.process_date    >= s.time_of_call_start - p.contract_lookback_days)
),
/* Chon T gan nhat RIENG tung CONTRACT_CODE + Ops, khong partition theo offer. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   PARTITION BY f.cuid, f.contract_code, f.username
                   ORDER BY f.time_of_call_start DESC NULLS LAST,
                            f.call_id DESC NULLS LAST,
                            f.appl_source ASC NULLS LAST,
                            f.orig_offer_id ASC NULLS LAST,
                            f.bod_date DESC NULLS LAST,
                            f.bod1_date DESC NULLS LAST,
                            f.media_server_ixn_guid DESC NULLS LAST
               ) AS rn_t
        FROM follow_candidates f
    ) WHERE rn_t = 1
),
/* Context khong phu thuoc ngay T: tinh 1 lan / HD + offer + source + Ops + BOD. */
contract_keys AS (
    SELECT DISTINCT cuid, contract_cuid, contract_code, orig_offer_id,
           appl_source, username, bod1_date, bod_date
    FROM follow_calls
    WHERE contract_code IS NOT NULL
),

/* 7. Gom IB/OB som nhat 1 lan / CUID + Ops; evaluated chi dung neu T0 < T.
   Khong gom theo HD khi co nhieu T: se gan sai T0 sau mot call T cu hon. */
t0 AS (
    SELECT x.cuid, x.username,
           MIN(x.time_of_call_start) AS time_of_call_start_t0
    FROM call_raw x
    WHERE x.call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls t
                  WHERE t.cuid = x.cuid AND t.username = x.username)
    GROUP BY x.cuid, x.username
),

/* 8. Loai call gan thoi diem len BOD (de biet HD tu IB/OB hay Manual/Personal) */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date,
        MIN(c.call_type) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
                c.time_of_call_start DESC NULLS LAST,
                c.call_id DESC NULLS LAST,
                c.call_uuid DESC NULLS LAST
        ) AS contract_call_type
    FROM contract_keys f
    JOIN calls_qc c
      ON c.cuid          = f.cuid
     AND c.username      = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date
),

/* 9. Lich su HD chi cho CUID co T; dung chung cho Step 3 va HD tiep theo.
   Khong loc TLS o day: chi Step 3 duoc thu hep, Next giu logic ban goc. */
appl_hist AS (
    SELECT /*+ MATERIALIZE */ u.*,
           /* DASH_VISIBLE = 1: HD hien tren dashboard QC07
              - offer cua HD co call QC07 (calls_qc) cung CUID
              - HD moi nhat (rnk = 1) theo nguon x CUID x offer, trong [date_from_t0, ...) */
           CASE WHEN u.preprocess_date >= p.date_from_t0
                 AND EXISTS (SELECT 1 FROM calls_qc q
                             WHERE q.cuid_num = u.cuid AND q.orig_offer_id = u.orig_offer_id)
                 AND ROW_NUMBER() OVER (
                         PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                         ORDER BY CASE WHEN u.preprocess_date >= p.date_from_t0 THEN 0 ELSE 1 END,
                                  u.preprocess_date DESC, u.contract_code DESC) = 1
                THEN 1 ELSE 0 END AS dash_visible
    FROM (
        SELECT a.cuid, a.contract_code, a.orig_offer_id,
               a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
               a.name_credit_status, 'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx a
        WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
        UNION ALL
        SELECT a.cuid, a.contract_code, a.orig_offer_id,
               a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
               a.name_credit_status, 'CCX'
        FROM ap_tls.tb_tls_appl_ccx a
        WHERE a.cuid IN (SELECT contract_cuid FROM contract_keys)
    ) u
    CROSS JOIN params p
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date,
        /* HD lien ke TRUOC: CHI xet HD hien tren dashboard QC07 (dash_visible = 1) */
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END) AS prev_bod1_date,
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.preprocess_date >= b.bod1_date - 14
                  AND h.dash_visible = 0 THEN h.contract_code END) AS hidden_prev_contract,
        MAX(h.contract_code) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_contract_raw,
        MAX(h.preprocess_user) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_bod1_user_raw,
        MAX(h.name_credit_status) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_status_raw,
        /* HD lien ke SAU: giu nguyen logic Next cua ban goc */
        MIN(CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                 THEN h.preprocess_date END) AS next_apply_date,
        MIN(h.contract_code) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_contract_raw,
        MIN(h.name_credit_status) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_status_raw
    FROM contract_keys b
    JOIN appl_hist h
      ON h.cuid           = b.contract_cuid
     AND h.contract_code <> b.contract_code
     AND (    h.preprocess_date < b.bod1_date
          OR (h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE))
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date
),

/* 10. Team / SUP */
emp AS (
    SELECT LOWER(username) AS username_lc, team, date_valid_from,
           NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h
    CROSS JOIN params p
    WHERE h.sup_name IS NOT NULL
      AND h.month >= TO_CHAR(p.date_from, 'YYYY-MM')
      AND h.month <= TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
),

/* 11. Cham diem */
evaluated AS (
    SELECT r.*,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
             THEN x.time_of_call_start_t0 END AS time_of_call_start_t0,
        mc.contract_call_type,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_contract_raw END AS next_apply_contract,
        v.next_apply_date,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_status_raw   END AS name_credit_status,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
              AND r.time_of_call_start - x.time_of_call_start_t0 <= 14
             THEN 1 ELSE 0 END AS result_step_1,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_contract_raw  END AS prev_contract,
        v.prev_bod1_date,
        v.hidden_prev_contract,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_bod1_user_raw END AS prev_bod1_user,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_status_raw    END AS prev_credit_status,
        CASE
            WHEN r.contract_code IS NULL                                          THEN 0
            WHEN r.map_type = 'Ops khac len HD'                                   THEN 0
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')                  THEN 1
            WHEN NVL(LOWER(r.bod1_user), '#') <> LOWER(r.username)                 THEN 0
            WHEN v.prev_bod1_date IS NULL                                         THEN 1
            WHEN LOWER(v.prev_bod1_user_raw) = LOWER(r.username)                  THEN 1
            WHEN r.bod1_date - v.prev_bod1_date <= 14                             THEN 0
            ELSE 1
        END AS result_step_3,
        CASE
            WHEN r.contract_code IS NULL
                THEN 'Ops khong len HD nao cua CUID + offer nay trong cua so'
            WHEN r.map_type = 'Ops khac len HD'
                THEN 'HD do ' || NVL(r.bod1_user, 'N/A') || '/' || NVL(r.bod2_user, 'N/A') || ' len, khong phai Ops nay'
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')
                THEN 'HD tu ' || mc.contract_call_type || ' -> khong xet 14 ngay'
            WHEN NVL(LOWER(r.bod1_user), '#') <> LOWER(r.username)
                THEN 'Ops khong len BOD1 (BOD1 boi ' || NVL(r.bod1_user, 'N/A') || ')'
            WHEN v.prev_bod1_date IS NULL
                THEN 'Khong co HD truoc tren dashboard'
                     || CASE WHEN v.hidden_prev_contract IS NOT NULL
                             THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
            WHEN LOWER(v.prev_bod1_user_raw) = LOWER(r.username)
                THEN 'HD truoc ' || v.prev_contract_raw || ' cung Ops'
            WHEN r.bod1_date - v.prev_bod1_date <= 14
                THEN 'HD truoc ' || v.prev_contract_raw || ' boi ' || NVL(v.prev_bod1_user_raw, 'N/A')
                     || ' (' || v.prev_status_raw || ') cach '
                     || CASE WHEN r.bod1_date - v.prev_bod1_date < 1
                             THEN TO_CHAR(ROUND((r.bod1_date - v.prev_bod1_date) * 24, 1)) || ' gio'
                             ELSE TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay' END
                     || ' <= 14 ngay'
            ELSE 'HD truoc ' || v.prev_contract_raw || ' boi Ops khac, cach '
                 || TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay > 14'
                 || CASE WHEN v.hidden_prev_contract IS NOT NULL
                         THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
        END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0 x ON x.cuid = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.username = r.username
                             AND mc.appl_source = r.appl_source AND mc.orig_offer_id = r.orig_offer_id
                             AND mc.bod_date = r.bod_date
    LEFT JOIN hist_context v ON v.cuid = r.cuid AND v.contract_code = r.contract_code AND v.username = r.username
                           AND v.appl_source = r.appl_source AND v.orig_offer_id = r.orig_offer_id
                           AND v.bod1_date = r.bod1_date
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                                   AS call_uuid,
    r.username,
    e.team,
    h.sup_name                                                AS sup,
    r.contract_call_type,
    r.call_type,
    r.time_of_call_start_t0,
    r.time_of_call_start                                      AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                               AS report_date,
    ROUND(r.time_of_call_start - r.time_of_call_start_t0, 2)  AS t_diff_t0,
    r.contract_code                                           AS first_apply_contract,
    r.appl_source,
    r.qc07_visible,                                           -- 1 = HD hien tren QC07; 0 = HD QC07 an
    r.map_type,
    r.contract_bod_date,
    r.contract_status,
    r.bod1_date,
    r.bod1_user,
    r.bod2_date,
    r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)               AS follow_dates,
    r.next_apply_contract,
    r.next_apply_date,
    r.name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract,
    r.prev_bod1_date,
    r.prev_bod1_user,
    r.prev_credit_status,
    r.hidden_prev_contract,                                   -- HD an tren QC07 trong 14 ngay, bi bo qua o Step 3
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                                    AS final_result
FROM evaluated r
LEFT JOIN emp e ON e.username_lc = r.username
               AND TRUNC(r.time_of_call_start) > e.date_valid_from 
               AND TRUNC(r.time_of_call_start) <= e.date_valid_to
LEFT JOIN hr  h ON h.op_username = r.username
               AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM');
               
               
               
               
               
               
               
               
               
               
        







--------------------------------------------------------------------------------
/* =====================================================================
   QC07 FOLLOW TRACKING - BAN TOI UU (Power BI) - 13/10/2026
   Ky     : 1 thang den het hom nay (+14 ngay lui cho T0, +lookback cho HD).
   Grain  : 1 dong / CUID + HD + Ops. Chi giu call T ghep duoc voi HD.
   Map HD : CUID + offer + chinh Ops len BOD1/BOD2 (ke ca HD QC07 an).
   T      = Manual Outbound / Personal Callback GAN NHAT / CUID + HD + Ops
   T0     = Inbound / Outbound SOM NHAT truoc T (cung CUID + Ops), co the NULL
   Step 1 = 1 khi T - T0 <= 14 ngay; > 14 ngay hoac khong co T0 -> 0
   Step 2 = cung Ops: T - BOD1 <= 30 hoac T - BOD2 <= 180 (khong chan BOD sau T)
   Step 3 = HD tu IB/OB -> 1; Ops khong len BOD1 -> 0;
            con lai xet HD LIEN KE TRUOC trong so HD HIEN TREN DASHBOARD QC07:
            khong co / cung Ops -> 1; Ops khac va cach <= 14 ngay -> 0; > 14 -> 1.
   Final  = Step 3 = 1 AND (Step 1 = 1 OR Step 2 = 1)
   ===================================================================== */
WITH params AS (
    SELECT TRUNC(SYSDATE)                       AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)       AS date_from,
           TRUNC(SYSDATE) + 1                   AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14  AS date_from_t0,  -- lui 14 ngay de khong mat T0 cua T dau ky
           90                                   AS contract_lookback_days  -- 30 = 1 thang, 90 = 3 thang truoc T
    FROM dual
),

/* 1. Call goc: ky bao cao + 14 ngay lui (cho T0). Chi lay cot can dung. */
call_raw AS (
    SELECT /*+ MATERIALIZE PARALLEL(sas, 8) */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid,
        sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE
            WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                THEN 'Personal Callback'
            WHEN sas.type_tls_call = 'OB_Man'
             AND sas.target_object_selected NOT LIKE '%INBOUND%'
             AND sas.interaction_type_key = 3
                THEN 'Manual Outbound'
            ELSE sas.call_type
        END AS call_type
    FROM ap_tls.tb_tls_call_sas sas
    CROSS JOIN params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (   sas.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                              'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
           OR sas.call_type IN ('Inbound', 'Outbound'))
--      AND sas.cuid IN ('7983363', '7395011','10265370','10242093','11210500','153012197')   -- TEST: xoa dong nay khi chay full
),

/* 2. Call len dashboard (dieu kien QC07) */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
        COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c
    CROSS JOIN params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. Khu trung grain: chi grain bi trung moi can scoring theo uu tien QC07 */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re
    CROSS JOIN params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX', 'CCX', 'CC_CC', 'ACLX', 'ACLLG', 'XNA', 'SAI', 'ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT d.cuid_num FROM calls_qc d WHERE d.grain_count > 1)
),
duplicate_ranked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
            ORDER BY
                CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END ASC NULLS LAST
        ) AS rn
    FROM calls_qc c
    LEFT JOIN scoring sc ON sc.id_cuid = c.cuid_num
    WHERE c.grain_count > 1
),

/* 4. Chi giu call T (Manual/Personal) sau khi khu trung -> giam manh so dong */
t_calls AS (
    SELECT c.* FROM calls_qc c
    WHERE c.grain_count = 1
      AND c.call_type IN ('Manual Outbound', 'Personal Callback')
    UNION ALL
    SELECT d.call_id, d.resource_role, d.interaction_resource_ordinal, d.call_uuid,
           d.media_server_ixn_guid, d.cuid, d.cuid_num, d.username, d.orig_offer_id,
           d.time_of_call_start, d.time_of_call_end, d.durations, d.channel,
           d.name_camp_call, d.call_type_raw, d.call_type, d.grain_count
    FROM duplicate_ranked d
    WHERE d.rn = 1
      AND d.call_type IN ('Manual Outbound', 'Personal Callback')
),

/* 5. Tat ca HD cua CUID + offer co call T (ca HD QC07 an).
   QC07_VISIBLE mo phong cach QC07 chon HD: trong ky, rnk = 1 theo nguon x CUID x offer. */
contract AS (
    SELECT u.*,
--           CASE WHEN u.preprocess_date >= p.date_from
--                 AND ROW_NUMBER() OVER (
--                         PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
--                         ORDER BY CASE WHEN u.preprocess_date >= p.date_from THEN 0 ELSE 1 END,
--                                  u.preprocess_date DESC) = 1
--                THEN 1 ELSE 0 END AS qc07_visible
           CASE WHEN u.preprocess_date >= p.date_from
                 AND ROW_NUMBER() OVER (
                         PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                         ORDER BY
                             CASE WHEN u.preprocess_date >= p.date_from
                                  THEN 0 ELSE 1 END,
                             u.preprocess_date DESC,
                             u.contract_code DESC
                     ) = 1
                THEN 1 ELSE 0 END AS qc07_visible
    FROM (
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx x
        CROSS JOIN params p0
--        WHERE (x.preprocess_date >= p0.date_from - p0.contract_lookback_days
--               OR x.process_date >= p0.date_from - p0.contract_lookback_days)
          AND EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid 
--                      AND tc.orig_offer_id = x.orig_offer_id
                      )
        UNION ALL
        SELECT x.cuid, x.contract_code, x.orig_offer_id, x.preprocess_date,
               x.preprocess_user, x.process_date, x.process_user, x.name_credit_status,
               'CCX'
        FROM ap_tls.tb_tls_appl_ccx x
        CROSS JOIN params p0
--        WHERE (x.preprocess_date >= p0.date_from - p0.contract_lookback_days
--               OR x.process_date >= p0.date_from - p0.contract_lookback_days)
          AND EXISTS (SELECT 1 FROM t_calls tc
                      WHERE tc.cuid_num = x.cuid 
--                      AND tc.orig_offer_id = x.orig_offer_id
                      )
    ) u
    CROSS JOIN params p
),

/* 6. Ghep call T voi HD: cung CUID + offer + chinh Ops len BOD1/BOD2, BOD trong cua so lookback */
follow_candidates AS (
    SELECT
            s.cuid, s.cuid_num, s.username, s.orig_offer_id, s.call_id,
            s.media_server_ixn_guid, s.call_type, s.time_of_call_start,
            a.cuid            AS contract_cuid,
            a.contract_code, a.appl_source,
            a.qc07_visible,
            NVL(a.process_date, a.preprocess_date) AS contract_bod_date,
            a.name_credit_status AS contract_status,
            a.preprocess_date AS bod1_date,
            a.preprocess_user AS bod1_user,
            a.process_date    AS bod2_date,
            a.process_user    AS bod2_user,
            CASE WHEN (a.preprocess_user = s.username AND s.time_of_call_start - a.preprocess_date <= 30)
                   OR (a.process_user    = s.username AND s.time_of_call_start - a.process_date    <= 180)
                 THEN 1 ELSE 0 END AS result_step_2,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN 'BOD2'
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN a.process_date
                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN a.preprocess_date END AS bod_date
        FROM t_calls s
        CROSS JOIN params p
        JOIN contract a
          ON a.cuid          = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         /* Chi gan HD ma CHINH Ops do len BOD1/BOD2 (ke ca HD QC07 an).
            HD cua Ops khac / user he thong KHONG thanh dong rieng, nhung van
            duoc Step 3 xet qua lich su appl_hist (cot prev_contract). */
         AND (a.preprocess_user = s.username 
--            OR a.process_user = s.username
            )   -- PHAI co ngoac
        AND a.qc07_visible = 1
         /* chi lay HD co BOD trong cua so 1/3 thang truoc T (khong chan BOD sau T) */
--         AND (   a.preprocess_date >= s.time_of_call_start - p.contract_lookback_days
--              OR a.process_date    >= s.time_of_call_start - p.contract_lookback_days)
),
/* Chon T gan nhat RIENG tung CONTRACT_CODE + Ops, khong partition theo offer. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   PARTITION BY f.cuid, f.contract_code, f.appl_source 
--                   f.username
--                   ORDER BY f.time_of_call_start DESC NULLS LAST,
--                            f.call_id DESC NULLS LAST,
--                            f.appl_source ASC NULLS LAST,
--                            f.orig_offer_id ASC NULLS LAST,
--                            f.bod_date DESC NULLS LAST,
--                            f.bod1_date DESC NULLS LAST,
--                            f.media_server_ixn_guid DESC NULLS LAST
            ORDER BY f.time_of_call_start DESC NULLS LAST,
                     f.call_id DESC NULLS LAST,
                     f.media_server_ixn_guid DESC NULLS LAST,
                     f.username ASC NULLS LAST
               ) AS rn_t
        FROM follow_candidates f
    ) WHERE rn_t = 1
),
/* Context khong phu thuoc ngay T: tinh 1 lan / HD + offer + source + Ops + BOD. */
contract_keys AS (
    SELECT DISTINCT cuid, contract_cuid, contract_code, orig_offer_id,
           appl_source, username, bod1_date, bod_date
    FROM follow_calls
    WHERE contract_code IS NOT NULL
),

/* 7. Gom IB/OB som nhat 1 lan / CUID + Ops; evaluated chi dung neu T0 < T.
   Khong gom theo HD khi co nhieu T: se gan sai T0 sau mot call T cu hon. */
t0 AS (
    SELECT x.cuid, x.username,
           MIN(x.time_of_call_start) AS time_of_call_start_t0
    FROM call_raw x
    WHERE x.call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls t
                  WHERE t.cuid = x.cuid AND t.username = x.username)
    GROUP BY x.cuid, x.username
),

/* 8. Loai call gan thoi diem len BOD (de biet HD tu IB/OB hay Manual/Personal) */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date,
        MIN(c.call_type) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
                c.time_of_call_start DESC NULLS LAST,
                c.call_id DESC NULLS LAST,
                c.call_uuid DESC NULLS LAST
        ) AS contract_call_type
    FROM contract_keys f
    JOIN calls_qc c
      ON c.cuid          = f.cuid
     AND c.username      = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date
),

/* 9. Lich su HD cho Step 3 (HD truoc) va HD sau */
/* Offer co call QC07 (gon, dung cho dash_visible) */
qc_offers AS (
    SELECT /*+ MATERIALIZE */ DISTINCT cuid_num, orig_offer_id FROM calls_qc
),
/* Moc som nhat can doc lich su cho moi CUID: BOD1 som nhat - 14 ngay */
hist_bound AS (
    SELECT contract_cuid, MIN(NVL(bod1_date, bod_date)) - 14 AS min_date
    FROM contract_keys
    GROUP BY contract_cuid
),
appl_hist AS (
    SELECT /*+ MATERIALIZE */ u.*,
           /* DASH_VISIBLE = 1: HD hien tren dashboard QC07
              - offer cua HD co call QC07 (calls_qc) cung CUID
              - HD moi nhat (rnk = 1) theo nguon x CUID x offer, trong [date_from_t0, ...) */
           CASE WHEN u.preprocess_date >= p.date_from_t0
                 AND EXISTS (SELECT 1 FROM qc_offers q
                             WHERE q.cuid_num = u.cuid AND q.orig_offer_id = u.orig_offer_id)
                 AND ROW_NUMBER() OVER (
                         PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                         ORDER BY CASE WHEN u.preprocess_date >= p.date_from_t0 THEN 0 ELSE 1 END,
                                  u.preprocess_date DESC, u.contract_code DESC) = 1
                THEN 1 ELSE 0 END AS dash_visible
    FROM (
        SELECT a.cuid, a.contract_code, a.orig_offer_id,
               a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
               a.name_credit_status, 'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx a
        JOIN hist_bound hb ON hb.contract_cuid = a.cuid
        WHERE a.preprocess_date >= hb.min_date
        UNION ALL
        SELECT a.cuid, a.contract_code, a.orig_offer_id,
               a.preprocess_date, a.preprocess_user, a.process_date, a.process_user,
               a.name_credit_status, 'CCX'
        FROM ap_tls.tb_tls_appl_ccx a
        JOIN hist_bound hb ON hb.contract_cuid = a.cuid
        WHERE a.preprocess_date >= hb.min_date
    ) u
    CROSS JOIN params p
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date,
        /* HD lien ke TRUOC: CHI xet HD hien tren dashboard QC07 (dash_visible = 1) */
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END) AS prev_bod1_date,
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.preprocess_date >= b.bod1_date - 14
                  AND h.dash_visible = 0 THEN h.contract_code END) AS hidden_prev_contract,
        MAX(h.contract_code) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_contract_raw,
        MAX(h.preprocess_user) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_bod1_user_raw,
        MAX(h.name_credit_status) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_status_raw,
        /* HD lien ke SAU: giu nguyen logic Next cua ban goc */
        MIN(CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                 THEN h.preprocess_date END) AS next_apply_date,
        MIN(h.contract_code) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_contract_raw,
        MIN(h.name_credit_status) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_status_raw
    FROM contract_keys b
    JOIN appl_hist h
      ON h.cuid           = b.contract_cuid
     AND h.contract_code <> b.contract_code
     AND (    h.preprocess_date < b.bod1_date
          OR (h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE))
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date
),

/* 10. Team / SUP */
emp AS (
    SELECT LOWER(username) AS username_lc, team, date_valid_from,
           NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h
    CROSS JOIN params p
    WHERE h.sup_name IS NOT NULL
      AND h.month >= TO_CHAR(p.date_from, 'YYYY-MM')
      AND h.month <= TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
),

/* 11. Cham diem */
evaluated AS (
    SELECT r.*,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
             THEN x.time_of_call_start_t0 END AS time_of_call_start_t0,
        mc.contract_call_type,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_contract_raw END AS next_apply_contract,
        v.next_apply_date,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_status_raw   END AS name_credit_status,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
              AND r.time_of_call_start - x.time_of_call_start_t0 <= 14
             THEN 1 ELSE 0 END AS result_step_1,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_contract_raw  END AS prev_contract,
        v.prev_bod1_date,
        v.hidden_prev_contract,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_bod1_user_raw END AS prev_bod1_user,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_status_raw    END AS prev_credit_status,
        CASE
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')                  THEN 1
            WHEN NVL(r.bod1_user, '#') <> r.username                 THEN 0
            WHEN v.prev_bod1_date IS NULL                                         THEN 1
            WHEN v.prev_bod1_user_raw = r.username                  THEN 1
            WHEN r.bod1_date - v.prev_bod1_date <= 14                             THEN 0
            ELSE 1
        END AS result_step_3,
        CASE
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')
                THEN 'HD tu ' || mc.contract_call_type || ' -> khong xet 14 ngay'
            WHEN NVL(r.bod1_user, '#') <> r.username
                THEN 'Ops khong len BOD1 (BOD1 boi ' || NVL(r.bod1_user, 'N/A') || ')'
            WHEN v.prev_bod1_date IS NULL
                THEN 'Khong co HD truoc tren dashboard'
                     || CASE WHEN v.hidden_prev_contract IS NOT NULL
                             THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
            WHEN v.prev_bod1_user_raw = r.username
                THEN 'HD truoc ' || v.prev_contract_raw || ' cung Ops'
            WHEN r.bod1_date - v.prev_bod1_date <= 14
                THEN 'HD truoc ' || v.prev_contract_raw || ' boi ' || NVL(v.prev_bod1_user_raw, 'N/A')
                     || ' (' || v.prev_status_raw || ') cach '
                     || CASE WHEN r.bod1_date - v.prev_bod1_date < 1
                             THEN TO_CHAR(ROUND((r.bod1_date - v.prev_bod1_date) * 24, 1)) || ' gio'
                             ELSE TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay' END
                     || ' <= 14 ngay'
            ELSE 'HD truoc ' || v.prev_contract_raw || ' boi Ops khac, cach '
                 || TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay > 14'
                 || CASE WHEN v.hidden_prev_contract IS NOT NULL
                         THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
        END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0 x ON x.cuid = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.username = r.username
                             AND mc.appl_source = r.appl_source AND mc.orig_offer_id = r.orig_offer_id
                             AND mc.bod_date = r.bod_date
    LEFT JOIN hist_context v ON v.cuid = r.cuid AND v.contract_code = r.contract_code AND v.username = r.username
                           AND v.appl_source = r.appl_source AND v.orig_offer_id = r.orig_offer_id
                           AND v.bod1_date = r.bod1_date
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                                   AS call_uuid,
    r.username,
    e.team,
    h.sup_name                                                AS sup,
    r.contract_call_type,
    r.call_type,
    r.time_of_call_start_t0,
    r.time_of_call_start                                      AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                               AS report_date,
    ROUND(r.time_of_call_start - r.time_of_call_start_t0, 2)  AS t_diff_t0,
    r.contract_code                                           AS first_apply_contract,
    r.appl_source,
    r.qc07_visible,                                           -- 1 = HD hien tren QC07; 0 = HD QC07 an
    r.contract_bod_date,
    r.contract_status,
    r.bod1_date,
    r.bod1_user,
    r.bod2_date,
    r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)               AS follow_dates,
    r.next_apply_contract,
    r.next_apply_date,
    r.name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract,
    r.prev_bod1_date,
    r.prev_bod1_user,
    r.prev_credit_status,
    r.hidden_prev_contract,                                   -- HD an tren QC07 trong 14 ngay, bi bo qua o Step 3
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                                    AS final_result
FROM evaluated r
LEFT JOIN emp e ON e.username_lc = LOWER(r.username)
               AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to
LEFT JOIN hr  h ON h.op_username = r.username
               AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM')
order by r.cuid
               ;









-----------------------------------


/* QC07 FOLLOW TRACKING - UPDATED 14/10/2026
   BASE: Pasted text(6).txt
   - T: Manual Outbound/Personal Callback trong 3 THANG gan nhat.
   - Giu moi tuoi hop dong, ca HD an/ngoai ky, nhung van CUNG CUID + offer.
   - Khong loc username = preprocess_user o JOIN chon hop dong.
   - Mot dong / CUID + CONTRACT_CODE + APPL_SOURCE, lay T gan nhat giua cac Ops.
     Khi bo loc Ops, nguoi goi duoc chon va Step 1/3 co the doi theo T moi.
   - Step 2 khong xet user: T-BOD1 <=30 HOAC T-BOD2 <=180.
     Giu rule <=, KHONG them dieu kien BOD truoc T. NULL khong lam nhanh dat.
   - Step 2 = 0 chi khi khong nhanh nao dat. BOD2 >180 van co the dat BOD1.
   - stage/bod_date va rule Step 3 giu nguyen nhu ban nguon.
     Cac cot nay van gan voi Ops; KHONG dung follow_dates de kiem tra BOD2.
     Dung days_since_bod1/days_since_bod2 cho hai khoang ngay rieng.
   - HD an hien thanh dong nhung KHONG thanh HD truoc chan Step 3.
     Visibility Step 3 la tap mo phong cua KY HIEN TAI, khong phai lich su
     dashboard tai ngay BOD cu. Khong co HD truoc trong tap nay -> 1, nhu goc.
   - QC07_VISIBLE chi mo phong SQL nguon, chua doi chieu procedure QC07.
   - HIDDEN_PREV_CONTRACT = MAX(ma HD an), khong phai danh sach/HD gan nhat.
   - JOIN employee co the nhan dong neu hieu luc nhan su chong lan.
   - SELECT cuoi mac dinh lay TAT CA; WHERE >180 chi la dong test da comment.
   - Da kiem tra parser/du lieu mau; chua chay Oracle hay do performance.
*/
WITH params AS (
    SELECT TRUNC(SYSDATE)                       AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -3)       AS date_from,
           TRUNC(SYSDATE) + 1                   AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -3) - 14  AS date_from_t0  -- lui 14 ngay cho T0
    FROM dual
),

/* 1. Call goc: ky bao cao + 14 ngay lui (cho T0). Chi lay cot can dung. */
call_raw AS (
    SELECT /*+ MATERIALIZE PARALLEL(sas, 8) */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid,
        sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE
            WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                THEN 'Personal Callback'
            WHEN sas.type_tls_call = 'OB_Man'
             AND sas.target_object_selected NOT LIKE '%INBOUND%'
             AND sas.interaction_type_key = 3
                THEN 'Manual Outbound'
            ELSE sas.call_type
        END AS call_type
    FROM ap_tls.tb_tls_call_sas sas
    CROSS JOIN params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (   sas.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                              'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
           OR sas.call_type IN ('Inbound', 'Outbound'))
--      AND sas.cuid IN ('7983363', '7395011','10265370','10242093','11210500','153012197','10823694')   -- TEST: xoa dong nay khi chay full
),

/* 2. Call len dashboard (dieu kien QC07) */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
        COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c
    CROSS JOIN params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. Khu trung grain: chi grain bi trung moi can scoring theo uu tien QC07 */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re
    CROSS JOIN params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX', 'CCX', 'CC_CC', 'ACLX', 'ACLLG', 'XNA', 'SAI', 'ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT d.cuid_num FROM calls_qc d WHERE d.grain_count > 1)
),
duplicate_ranked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
            ORDER BY
                CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END ASC NULLS LAST
        ) AS rn
    FROM calls_qc c
    LEFT JOIN scoring sc ON sc.id_cuid = c.cuid_num
    WHERE c.grain_count > 1
),

/* 4. Chi giu call T (Manual/Personal) sau khi khu trung -> giam manh so dong */
t_calls AS (
    SELECT c.* FROM calls_qc c
    WHERE c.grain_count = 1
      AND c.call_type IN ('Manual Outbound', 'Personal Callback')
    UNION ALL
    SELECT d.call_id, d.resource_role, d.interaction_resource_ordinal, d.call_uuid,
           d.media_server_ixn_guid, d.cuid, d.cuid_num, d.username, d.orig_offer_id,
           d.time_of_call_start, d.time_of_call_end, d.durations, d.channel,
           d.name_camp_call, d.call_type_raw, d.call_type, d.grain_count
    FROM duplicate_ranked d
    WHERE d.rn = 1
      AND d.call_type IN ('Manual Outbound', 'Personal Callback')
),

/* 5. Toan bo lich su HD cua CUID co T; KHONG gioi han tuoi HD.
   Rank truoc khi loc Ops de co khong thay doi theo nguoi goi.
   Hai co visibility chi MO PHONG rule trong script nguon, chua xac nhan
   bang procedure QC07 goc. Khong dung cac co nay de loai dong bao cao. */
contract_base AS (
    SELECT /*+ MATERIALIZE */ x.cuid, x.contract_code, x.orig_offer_id,
           x.preprocess_date, x.preprocess_user, x.process_date,
           x.process_user, x.name_credit_status, 'CLX' AS appl_source
    FROM ap_tls.tb_tls_appl_clx x
    WHERE EXISTS (SELECT 1 FROM t_calls tc WHERE tc.cuid_num = x.cuid)
    UNION ALL
    SELECT x.cuid, x.contract_code, x.orig_offer_id,
           x.preprocess_date, x.preprocess_user, x.process_date,
           x.process_user, x.name_credit_status, 'CCX' AS appl_source
    FROM ap_tls.tb_tls_appl_ccx x
    WHERE EXISTS (SELECT 1 FROM t_calls tc WHERE tc.cuid_num = x.cuid)
),
contract_ranked AS (
    SELECT b.*,
           ROW_NUMBER() OVER (
               PARTITION BY b.appl_source, b.cuid, b.orig_offer_id
               ORDER BY b.preprocess_date DESC NULLS LAST, b.contract_code DESC
           ) AS rn_contract
    FROM contract_base b
),
contract AS (
    SELECT b.*,
           CASE WHEN b.preprocess_date >= p.date_from AND b.rn_contract = 1
                THEN 1 ELSE 0 END AS qc07_visible,
           CASE WHEN b.preprocess_date IS NULL THEN 'NO_BOD1_DATE'
                WHEN b.preprocess_date < p.date_from THEN 'OUTSIDE_REPORT_PERIOD'
                WHEN b.rn_contract > 1 THEN 'HIDDEN_BY_OFFER_RANK'
                ELSE 'QC07_VISIBLE_RULE' END AS contract_scope
    FROM contract_ranked b
    CROSS JOIN params p
),
/* Bo loc tuoi HD khong con phu thuoc T, nen chon T moi nhat truoc JOIN.
   Voi cung CUID + offer + Ops, chon T gan nhat truoc khi ghep cac HD cung offer. */
t_latest AS (
    SELECT * FROM (
        SELECT t.*,
               ROW_NUMBER() OVER (
                   PARTITION BY t.cuid_num, t.orig_offer_id, t.username
                   ORDER BY t.time_of_call_start DESC NULLS LAST,
                            t.call_id DESC NULLS LAST,
                            t.media_server_ixn_guid DESC NULLS LAST
               ) AS rn_latest
        FROM t_calls t
    ) WHERE rn_latest = 1
),

/* 6. Ghep cung CUID + offer, KHONG bat buoc cung nguoi len BOD1/BOD2.
   Giu HD cu/HD an; khong loc tuoi HD, qc07_visible hay result_step_2.
   Step 2 CHI XET NGAY: T-BOD1 <=30 HOAC T-BOD2 <=180.
   Giu rule <= cua ban: so am (BOD sau T) van co the dat.
   stage/bod_date van phu thuoc Ops de giu cach map call cho Step 3. */
follow_candidates AS (
    SELECT
            s.cuid, s.cuid_num, s.username, s.orig_offer_id, s.call_id,
            s.media_server_ixn_guid, s.call_type, s.time_of_call_start,
            a.cuid            AS contract_cuid,
            a.contract_code, a.appl_source,
            a.qc07_visible, a.contract_scope,
            NVL(a.process_date, a.preprocess_date) AS contract_bod_date,
            a.name_credit_status AS contract_status,
            a.preprocess_date AS bod1_date,
            a.preprocess_user AS bod1_user,
            a.process_date    AS bod2_date,
            a.process_user    AS bod2_user,
            CASE WHEN (s.time_of_call_start - a.preprocess_date <= 30)
                   OR (s.time_of_call_start - a.process_date    <= 180)
                 THEN 1 ELSE 0 END AS result_step_2,
--            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN 'BOD2'
--                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
--            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN a.process_date
--                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN a.preprocess_date END AS bod_date
            CASE WHEN a.process_date IS NOT NULL THEN 'BOD2'
                 WHEN a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
            NVL(a.process_date, a.preprocess_date)                 AS bod_date,
        FROM t_latest s
        JOIN contract a
          ON a.cuid = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
),
/* Mot dong / CUID + CONTRACT_CODE + APPL_SOURCE, nhu ban nguon. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   PARTITION BY f.cuid, f.contract_code, f.appl_source 
            ORDER BY f.time_of_call_start DESC NULLS LAST,
                     f.call_id DESC NULLS LAST,
                     f.media_server_ixn_guid DESC NULLS LAST,
                     f.username ASC NULLS LAST
               ) AS rn_t
        FROM follow_candidates f
    ) WHERE rn_t = 1
),
/* Context khong phu thuoc ngay T: tinh 1 lan / HD + offer + source + Ops + BOD. */
contract_keys AS (
    SELECT DISTINCT cuid, contract_cuid, contract_code, orig_offer_id,
           appl_source, username, bod1_date, bod_date
    FROM follow_calls
    WHERE contract_code IS NOT NULL
),

/* 7. Gom IB/OB som nhat 1 lan / CUID + Ops; evaluated chi dung neu T0 < T.
   Khong gom theo HD khi co nhieu T: se gan sai T0 sau mot call T cu hon. */
t0 AS (
    SELECT x.cuid, x.username,
           MIN(x.time_of_call_start) AS time_of_call_start_t0
    FROM call_raw x
    WHERE x.call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls t
                  WHERE t.cuid = x.cuid AND t.username = x.username)
    GROUP BY x.cuid, x.username
),

/* 8. Loai call gan thoi diem len BOD (de biet HD tu IB/OB hay Manual/Personal) */
contract_call_recent AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date,
        MIN(c.call_type) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
                c.time_of_call_start DESC NULLS LAST,
                c.call_id DESC NULLS LAST,
                c.call_uuid DESC NULLS LAST
        ) AS contract_call_type
    FROM contract_keys f
    JOIN calls_qc c
      ON c.cuid          = f.cuid
     AND c.username      = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date
),

/* calls_qc chi chua call trong ky. Tra call cu tai ngay BOD de
   khong mat mien tru IB/OB khi HD duoc len truoc ky bao cao.
   Giu nguyen rule: call chua BOD hoac call som hon trong cung ngay.
   Neu khong co lich su call trong bang nguon, loai call van la NULL. */
contract_call_old AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source,
           f.orig_offer_id, f.bod_date,
           MIN(
               CASE
                   WHEN c.call_type = 'Outbound' AND c.record_type = 'Personal Callback'
                       THEN 'Personal Callback'
                   WHEN c.type_tls_call = 'OB_Man'
                    AND c.target_object_selected NOT LIKE '%INBOUND%'
                    AND c.interaction_type_key = 3 THEN 'Manual Outbound'
                   ELSE c.call_type
               END
           ) KEEP (
               DENSE_RANK FIRST ORDER BY
                   CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end
                        THEN 0 ELSE 1 END,
                   c.time_of_call_start DESC NULLS LAST,
                   c.call_id DESC NULLS LAST,
                   c.call_uuid DESC NULLS LAST
           ) AS contract_call_type
    FROM contract_keys f
    CROSS JOIN params p
    JOIN ap_tls.tb_tls_call_sas c
      ON c.cuid = f.cuid
     AND c.username = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date
          OR c.time_of_call_start >= TRUNC(f.bod_date))
    WHERE f.bod_date < p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (c.durations > 0
           OR (c.durations = 0 AND c.call_type = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type = 'Outbound' AND c.name_camp_call IS NULL))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source,
             f.orig_offer_id, f.bod_date
),
contract_call AS (
    SELECT * FROM contract_call_recent
    UNION ALL
    SELECT * FROM contract_call_old
),

/* 9. Lich su HD cho Step 3 (HD truoc) va HD sau */
/* Offer co call QC07 (gon, dung cho dash_visible) */
qc_offers AS (
    SELECT /*+ MATERIALIZE */ DISTINCT cuid_num, orig_offer_id FROM calls_qc
),
/* Moc som nhat can doc lich su cho moi CUID: BOD1 som nhat - 14 ngay */
hist_bound AS (
    SELECT contract_cuid, MIN(NVL(bod1_date, bod_date)) - 14 AS min_date
    FROM contract_keys
    GROUP BY contract_cuid
),
/* Step 3 giu tap tham chieu cua ban nguon: hop dong moi nhat /
   nguon + CUID + offer, BOD1 >= date_from_t0 va offer co call QC trong ky.
   Viec hien HD an thanh dong KHONG bien HD an thanh prev_contract.
   Day la visibility o KY HIEN TAI, khong phai anh chup QC07 tai ngay BOD cu. */
appl_hist AS (
    SELECT /*+ MATERIALIZE */ u.*,
           CASE WHEN u.preprocess_date >= p.date_from_t0
                 AND u.rn_contract = 1
                 AND EXISTS (
                     SELECT 1 FROM qc_offers q
                     WHERE q.cuid_num = u.cuid AND q.orig_offer_id = u.orig_offer_id
                 )
                THEN 1 ELSE 0 END AS dash_visible
    FROM contract_ranked u
    JOIN hist_bound hb ON hb.contract_cuid = u.cuid
    CROSS JOIN params p
    WHERE u.preprocess_date >= hb.min_date
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date,
        /* HD lien ke TRUOC: CHI xet HD hien tren dashboard QC07 (dash_visible = 1) */
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END) AS prev_bod1_date,
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.preprocess_date >= b.bod1_date - 14
                  AND h.dash_visible = 0 THEN h.contract_code END) AS hidden_prev_contract,
        MAX(h.contract_code) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_contract_raw,
        MAX(h.preprocess_user) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_bod1_user_raw,
        MAX(h.name_credit_status) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_status_raw,
        /* HD lien ke SAU: giu nguyen logic Next cua ban goc */
        MIN(CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                 THEN h.preprocess_date END) AS next_apply_date,
        MIN(h.contract_code) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_contract_raw,
        MIN(h.name_credit_status) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_status_raw
    FROM contract_keys b
    JOIN appl_hist h
      ON h.cuid           = b.contract_cuid
     AND h.contract_code <> b.contract_code
     AND (    h.preprocess_date < b.bod1_date
          OR (h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE))
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date
),

/* 10. Team / SUP */
emp AS (
    SELECT DISTINCT LOWER(username) AS username_lc, team, date_valid_from,
           NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h
    CROSS JOIN params p
    WHERE h.sup_name IS NOT NULL
      AND h.month >= TO_CHAR(p.date_from, 'YYYY-MM')
      AND h.month <= TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
),

/* 11. Cham diem */
evaluated AS (
    SELECT r.*,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
             THEN x.time_of_call_start_t0 END AS time_of_call_start_t0,
        mc.contract_call_type,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_contract_raw END AS next_apply_contract,
        v.next_apply_date,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_status_raw   END AS name_credit_status,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
              AND r.time_of_call_start - x.time_of_call_start_t0 <= 14
             THEN 1 ELSE 0 END AS result_step_1,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_contract_raw  END AS prev_contract,
        v.prev_bod1_date,
        v.hidden_prev_contract,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_bod1_user_raw END AS prev_bod1_user,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_status_raw    END AS prev_credit_status,
        CASE
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')                  THEN 1
            WHEN NVL(r.bod1_user, '#') <> r.username                 THEN 0
            WHEN v.prev_bod1_date IS NULL                                         THEN 1
            WHEN v.prev_bod1_user_raw = r.username                  THEN 1
            WHEN r.bod1_date - v.prev_bod1_date <= 14                             THEN 0
            ELSE 1
        END AS result_step_3,
        CASE
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')
                THEN 'HD tu ' || mc.contract_call_type || ' -> khong xet 14 ngay'
            WHEN NVL(r.bod1_user, '#') <> r.username
                THEN 'Ops khong len BOD1 (BOD1 boi ' || NVL(r.bod1_user, 'N/A') || ')'
            WHEN v.prev_bod1_date IS NULL
                THEN 'Khong co HD truoc tren dashboard'
                     || CASE WHEN v.hidden_prev_contract IS NOT NULL
                             THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
            WHEN v.prev_bod1_user_raw = r.username
                THEN 'HD truoc ' || v.prev_contract_raw || ' cung Ops'
            WHEN r.bod1_date - v.prev_bod1_date <= 14
                THEN 'HD truoc ' || v.prev_contract_raw || ' boi ' || NVL(v.prev_bod1_user_raw, 'N/A')
                     || ' (' || v.prev_status_raw || ') cach '
                     || CASE WHEN r.bod1_date - v.prev_bod1_date < 1
                             THEN TO_CHAR(ROUND((r.bod1_date - v.prev_bod1_date) * 24, 1)) || ' gio'
                             ELSE TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay' END
                     || ' <= 14 ngay'
            ELSE 'HD truoc ' || v.prev_contract_raw || ' boi Ops khac, cach '
                 || TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay > 14'
                 || CASE WHEN v.hidden_prev_contract IS NOT NULL
                         THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
        END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0 x ON x.cuid = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.username = r.username
                             AND mc.appl_source = r.appl_source AND mc.orig_offer_id = r.orig_offer_id
                             AND mc.bod_date = r.bod_date
    LEFT JOIN hist_context v ON v.cuid = r.cuid AND v.contract_code = r.contract_code AND v.username = r.username
                           AND v.appl_source = r.appl_source AND v.orig_offer_id = r.orig_offer_id
                           AND v.bod1_date = r.bod1_date
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                                   AS call_uuid,
    r.username,
    e.team,
    h.sup_name                                                AS sup,
    r.contract_call_type,
    r.call_type,
    r.time_of_call_start_t0,
    r.time_of_call_start                                      AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                               AS report_date,
    ROUND(r.time_of_call_start - r.time_of_call_start_t0, 2)  AS t_diff_t0,
    r.contract_code                                           AS first_apply_contract,
    r.appl_source,
    r.qc07_visible,  -- co mo phong, khong phai danh sach QC07 da xac nhan
    r.contract_scope,
    r.contract_bod_date,
    r.contract_status,
    r.bod1_date,
    r.bod1_user,
    r.bod2_date,
    r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)               AS follow_dates,
    ROUND(r.time_of_call_start - r.bod1_date, 2) AS days_since_bod1,
    ROUND(r.time_of_call_start - r.bod2_date, 2) AS days_since_bod2,
    r.next_apply_contract,
    r.next_apply_date,
    r.name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract,
    r.prev_bod1_date,
    r.prev_bod1_user,
    r.prev_credit_status,
    r.hidden_prev_contract,                                   -- HD an tren QC07 trong 14 ngay, bi bo qua o Step 3
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                                    AS final_result
FROM evaluated r
LEFT JOIN emp e ON e.username_lc = LOWER(r.username)
               AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to
LEFT JOIN hr  h ON h.op_username = r.username
               AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM')
-- WHERE r.time_of_call_start - r.bod2_date > 180
ORDER BY r.cuid, r.bod1_date, r.contract_code;
------------

















/* QC07 FOLLOW TRACKING - UPDATED 14/10/2026
   BASE: Pasted text(6).txt
   - T: Manual Outbound/Personal Callback trong 3 THANG gan nhat.
   - Giu moi tuoi hop dong, ca HD an/ngoai ky, nhung van CUNG CUID + offer.
   - Khong loc username = preprocess_user o JOIN chon hop dong.
   - Mot dong / CUID + CONTRACT_CODE + APPL_SOURCE, lay T gan nhat giua cac Ops.
     Khi bo loc Ops, nguoi goi duoc chon va Step 1/3 co the doi theo T moi.
   - Step 2 khong xet user: T-BOD1 <=30 HOAC T-BOD2 <=180.
     Giu rule <=, KHONG them dieu kien BOD truoc T. NULL khong lam nhanh dat.
   - Step 2 = 0 chi khi khong nhanh nao dat. BOD2 >180 van co the dat BOD1.
   - stage/bod_date va rule Step 3 giu nguyen nhu ban nguon.
     Cac cot nay van gan voi Ops; KHONG dung follow_dates de kiem tra BOD2.
     Dung days_since_bod1/days_since_bod2 cho hai khoang ngay rieng.
   - HD an hien thanh dong nhung KHONG thanh HD truoc chan Step 3.
     Visibility Step 3 la tap mo phong cua KY HIEN TAI, khong phai lich su
     dashboard tai ngay BOD cu. Khong co HD truoc trong tap nay -> 1, nhu goc.
   - QC07_VISIBLE chi mo phong SQL nguon, chua doi chieu procedure QC07.
   - HIDDEN_PREV_CONTRACT = MAX(ma HD an), khong phai danh sach/HD gan nhat.
   - JOIN employee co the nhan dong neu hieu luc nhan su chong lan.
   - SELECT cuoi mac dinh lay TAT CA; WHERE >180 chi la dong test da comment.
   - Da kiem tra parser/du lieu mau; chua chay Oracle hay do performance.
*/
WITH params AS (
    SELECT TRUNC(SYSDATE)                       AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)       AS date_from,
           TRUNC(SYSDATE) + 1                   AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14  AS date_from_t0  -- lui 14 ngay cho T0
    FROM dual
),

/* 1. Call goc: ky bao cao + 14 ngay lui (cho T0). Chi lay cot can dung. */
call_raw AS (
    SELECT /*+ MATERIALIZE PARALLEL(sas, 8) */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid,
        sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE
            WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                THEN 'Personal Callback'
            WHEN sas.type_tls_call = 'OB_Man'
             AND sas.target_object_selected NOT LIKE '%INBOUND%'
             AND sas.interaction_type_key = 3
                THEN 'Manual Outbound'
            ELSE sas.call_type
        END AS call_type
    FROM ap_tls.tb_tls_call_sas sas
    CROSS JOIN params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (   sas.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                              'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
           OR sas.call_type IN ('Inbound', 'Outbound'))
      AND sas.cuid IN (
--      '7983363', '7395011','10265370','10242093','11210500','153012197','10823694'
        '31718034'
      )   -- TEST: xoa dong nay khi chay full
),

/* 2. Call len dashboard (dieu kien QC07) */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
        COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c
    CROSS JOIN params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. Khu trung grain: chi grain bi trung moi can scoring theo uu tien QC07 */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re
    CROSS JOIN params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX', 'CCX', 'CC_CC', 'ACLX', 'ACLLG', 'XNA', 'SAI', 'ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT d.cuid_num FROM calls_qc d WHERE d.grain_count > 1)
),
duplicate_ranked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
            ORDER BY
                CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END ASC NULLS LAST,
                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END ASC NULLS LAST
        ) AS rn
    FROM calls_qc c
    LEFT JOIN scoring sc ON sc.id_cuid = c.cuid_num
    WHERE c.grain_count > 1
),

/* 4. Chi giu call T (Manual/Personal) sau khi khu trung -> giam manh so dong */
t_calls AS (
    SELECT c.* FROM calls_qc c
    WHERE c.grain_count = 1
      AND c.call_type IN ('Manual Outbound', 'Personal Callback')
    UNION ALL
    SELECT d.call_id, d.resource_role, d.interaction_resource_ordinal, d.call_uuid,
           d.media_server_ixn_guid, d.cuid, d.cuid_num, d.username, d.orig_offer_id,
           d.time_of_call_start, d.time_of_call_end, d.durations, d.channel,
           d.name_camp_call, d.call_type_raw, d.call_type, d.grain_count
    FROM duplicate_ranked d
    WHERE d.rn = 1
      AND d.call_type IN ('Manual Outbound', 'Personal Callback')
),

/* 5. Toan bo lich su HD cua CUID co T; KHONG gioi han tuoi HD.
   Rank truoc khi loc Ops de co khong thay doi theo nguoi goi.
   Hai co visibility chi MO PHONG rule trong script nguon, chua xac nhan
   bang procedure QC07 goc. Khong dung cac co nay de loai dong bao cao. */
contract_base AS (
    SELECT /*+ MATERIALIZE */ x.cuid, x.contract_code, x.orig_offer_id,
           x.preprocess_date, x.preprocess_user, x.process_date,
           x.process_user, x.name_credit_status, 'CLX' AS appl_source
    FROM ap_tls.tb_tls_appl_clx x
    WHERE EXISTS (SELECT 1 FROM t_calls tc WHERE tc.cuid_num = x.cuid)
    UNION ALL
    SELECT x.cuid, x.contract_code, x.orig_offer_id,
           x.preprocess_date, x.preprocess_user, x.process_date,
           x.process_user, x.name_credit_status, 'CCX' AS appl_source
    FROM ap_tls.tb_tls_appl_ccx x
    WHERE EXISTS (SELECT 1 FROM t_calls tc WHERE tc.cuid_num = x.cuid)
),
contract_ranked AS (
    SELECT b.*,
           ROW_NUMBER() OVER (
               PARTITION BY b.appl_source, b.cuid, b.orig_offer_id
               ORDER BY b.preprocess_date DESC NULLS LAST, b.contract_code DESC
           ) AS rn_contract
    FROM contract_base b
),
contract AS (
    SELECT b.*,
           CASE WHEN b.preprocess_date >= p.date_from AND b.rn_contract = 1
                THEN 1 ELSE 0 END AS qc07_visible,
           CASE WHEN b.preprocess_date IS NULL THEN 'NO_BOD1_DATE'
                WHEN b.preprocess_date < p.date_from THEN 'OUTSIDE_REPORT_PERIOD'
                WHEN b.rn_contract > 1 THEN 'HIDDEN_BY_OFFER_RANK'
                ELSE 'QC07_VISIBLE_RULE' END AS contract_scope
    FROM contract_ranked b
    CROSS JOIN params p
),
/* Bo loc tuoi HD khong con phu thuoc T, nen chon T moi nhat truoc JOIN.
   Voi cung CUID + offer + Ops, chon T gan nhat truoc khi ghep cac HD cung offer. */
t_latest AS (
    SELECT * FROM (
        SELECT t.*,
               ROW_NUMBER() OVER (
                   PARTITION BY t.cuid_num, t.orig_offer_id, t.username
                   ORDER BY t.time_of_call_start DESC NULLS LAST,
                            t.call_id DESC NULLS LAST,
                            t.media_server_ixn_guid DESC NULLS LAST
               ) AS rn_latest
        FROM t_calls t
    ) WHERE rn_latest = 1
),

/* 6. Ghep cung CUID + offer, KHONG bat buoc cung nguoi len BOD1/BOD2.
   Giu HD cu/HD an; khong loc tuoi HD, qc07_visible hay result_step_2.
   Step 2 CHI XET NGAY: T-BOD1 <=30 HOAC T-BOD2 <=180.
   Giu rule <= cua ban: so am (BOD sau T) van co the dat.
   stage/bod_date van phu thuoc Ops de giu cach map call cho Step 3. */
follow_candidates AS (
    SELECT
            s.cuid, s.cuid_num, s.username, s.orig_offer_id, s.call_id,
            s.media_server_ixn_guid, s.call_type, s.time_of_call_start,
            a.cuid            AS contract_cuid,
            a.contract_code, a.appl_source,
            a.qc07_visible, a.contract_scope,
            NVL(a.process_date, a.preprocess_date) AS contract_bod_date,
            a.name_credit_status AS contract_status,
            a.preprocess_date AS bod1_date,
            a.preprocess_user AS bod1_user,
            a.process_date    AS bod2_date,
            a.process_user    AS bod2_user,
            CASE WHEN (s.time_of_call_start - a.preprocess_date <= 30)
                   OR (s.time_of_call_start - a.process_date    <= 180)
                 THEN 1 ELSE 0 END AS result_step_2,
--            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN 'BOD2'
--                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
--            CASE WHEN a.process_user    = s.username AND a.process_date    IS NOT NULL THEN a.process_date
--                 WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN a.preprocess_date END AS bod_date
            CASE WHEN a.process_date IS NOT NULL THEN 'BOD2'
                 WHEN a.preprocess_date IS NOT NULL THEN 'BOD1' END AS stage,
            NVL(a.process_date, a.preprocess_date)                 AS bod_date
        FROM t_latest s
        JOIN contract a
          ON a.cuid = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         AND a.qc07_visible = 1          -- chi lay HD hien tren QC07, bo HD an
),
/* Mot dong / CUID + CONTRACT_CODE + APPL_SOURCE, nhu ban nguon. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   PARTITION BY f.cuid, f.contract_code, f.appl_source 
            ORDER BY f.time_of_call_start DESC NULLS LAST,
                     f.call_id DESC NULLS LAST,
                     f.media_server_ixn_guid DESC NULLS LAST,
                     f.username ASC NULLS LAST
               ) AS rn_t
        FROM follow_candidates f
    ) WHERE rn_t = 1
),
/* Context khong phu thuoc ngay T: tinh 1 lan / HD + offer + source + Ops + BOD. */
contract_keys AS (
    SELECT DISTINCT cuid, contract_cuid, contract_code, orig_offer_id,
           appl_source, username, bod1_date, bod_date
    FROM follow_calls
    WHERE contract_code IS NOT NULL
),

/* 7. Gom IB/OB som nhat 1 lan / CUID + Ops; evaluated chi dung neu T0 < T.
   Khong gom theo HD khi co nhieu T: se gan sai T0 sau mot call T cu hon. */
t0 AS (
    SELECT x.cuid, x.username,
           MIN(x.time_of_call_start) AS time_of_call_start_t0
    FROM call_raw x
    WHERE x.call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls t
                  WHERE t.cuid = x.cuid AND t.username = x.username)
    GROUP BY x.cuid, x.username
),

/* 8. Loai call gan thoi diem len BOD (de biet HD tu IB/OB hay Manual/Personal) */
contract_call_recent AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date,
        MIN(c.call_type) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
                c.time_of_call_start DESC NULLS LAST,
                c.call_id DESC NULLS LAST,
                c.call_uuid DESC NULLS LAST
        ) AS contract_call_type
    FROM contract_keys f
    JOIN calls_qc c
      ON c.cuid          = f.cuid
     AND c.username      = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source, f.orig_offer_id, f.bod_date
),

/* calls_qc chi chua call trong ky. Tra call cu tai ngay BOD de
   khong mat mien tru IB/OB khi HD duoc len truoc ky bao cao.
   Giu nguyen rule: call chua BOD hoac call som hon trong cung ngay.
   Neu khong co lich su call trong bang nguon, loai call van la NULL. */
contract_call_old AS (
    SELECT f.cuid, f.contract_code, f.username, f.appl_source,
           f.orig_offer_id, f.bod_date,
           MIN(
               CASE
                   WHEN c.call_type = 'Outbound' AND c.record_type = 'Personal Callback'
                       THEN 'Personal Callback'
                   WHEN c.type_tls_call = 'OB_Man'
                    AND c.target_object_selected NOT LIKE '%INBOUND%'
                    AND c.interaction_type_key = 3 THEN 'Manual Outbound'
                   ELSE c.call_type
               END
           ) KEEP (
               DENSE_RANK FIRST ORDER BY
                   CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end
                        THEN 0 ELSE 1 END,
                   c.time_of_call_start DESC NULLS LAST,
                   c.call_id DESC NULLS LAST,
                   c.call_uuid DESC NULLS LAST
           ) AS contract_call_type
    FROM contract_keys f
    CROSS JOIN params p
    JOIN ap_tls.tb_tls_call_sas c
      ON c.cuid = f.cuid
     AND c.username = f.username
     AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date
          OR c.time_of_call_start >= TRUNC(f.bod_date))
    WHERE f.bod_date < p.date_from
      AND c.channel IN ('CLX', 'ACLX', 'CCX', 'CCXP', 'SAI', 'ES',
                        'LEADER', 'TLS Business Excellence', 'SUP', 'QA-QC', 'QC')
      AND (c.durations > 0
           OR (c.durations = 0 AND c.call_type = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type = 'Outbound' AND c.name_camp_call IS NULL))
    GROUP BY f.cuid, f.contract_code, f.username, f.appl_source,
             f.orig_offer_id, f.bod_date
),
contract_call AS (
    SELECT * FROM contract_call_recent
    UNION ALL
    SELECT * FROM contract_call_old
),

/* 9. Lich su HD cho Step 3 (HD truoc) va HD sau */
/* Offer co call QC07 (gon, dung cho dash_visible) */
qc_offers AS (
    SELECT /*+ MATERIALIZE */ DISTINCT cuid_num, orig_offer_id FROM calls_qc
),
/* Moc som nhat can doc lich su cho moi CUID: BOD1 som nhat - 14 ngay */
hist_bound AS (
    SELECT contract_cuid, MIN(NVL(bod1_date, bod_date)) - 14 AS min_date
    FROM contract_keys
    GROUP BY contract_cuid
),
/* Step 3 giu tap tham chieu cua ban nguon: hop dong moi nhat /
   nguon + CUID + offer, BOD1 >= date_from_t0 va offer co call QC trong ky.
   Viec hien HD an thanh dong KHONG bien HD an thanh prev_contract.
   Day la visibility o KY HIEN TAI, khong phai anh chup QC07 tai ngay BOD cu. */
appl_hist AS (
    SELECT /*+ MATERIALIZE */ u.*,
           CASE WHEN u.preprocess_date >= p.date_from_t0
                 AND u.rn_contract = 1
                 AND EXISTS (
                     SELECT 1 FROM qc_offers q
                     WHERE q.cuid_num = u.cuid AND q.orig_offer_id = u.orig_offer_id
                 )
                THEN 1 ELSE 0 END AS dash_visible
    FROM contract_ranked u
    JOIN hist_bound hb ON hb.contract_cuid = u.cuid
    CROSS JOIN params p
    WHERE u.preprocess_date >= hb.min_date
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date,
        /* HD lien ke TRUOC: CHI xet HD hien tren dashboard QC07 (dash_visible = 1) */
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END) AS prev_bod1_date,
        MAX(CASE WHEN h.preprocess_date < b.bod1_date AND h.preprocess_date >= b.bod1_date - 14
                  AND h.dash_visible = 0 THEN h.contract_code END) AS hidden_prev_contract,
        MAX(h.contract_code) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_contract_raw,
        MAX(h.preprocess_user) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_bod1_user_raw,
        MAX(h.name_credit_status) KEEP (
            DENSE_RANK LAST ORDER BY
                CASE WHEN h.preprocess_date < b.bod1_date AND h.dash_visible = 1 THEN h.preprocess_date END NULLS FIRST,
                h.contract_code, h.appl_source
        ) AS prev_status_raw,
        /* HD lien ke SAU: giu nguyen logic Next cua ban goc */
        MIN(CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                 THEN h.preprocess_date END) AS next_apply_date,
        MIN(h.contract_code) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_contract_raw,
        MIN(h.name_credit_status) KEEP (
            DENSE_RANK FIRST ORDER BY
                CASE WHEN h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE
                     THEN h.preprocess_date END NULLS LAST,
                h.contract_code, h.appl_source
        ) AS next_status_raw
    FROM contract_keys b
    JOIN appl_hist h
      ON h.cuid           = b.contract_cuid
     AND h.contract_code <> b.contract_code
     AND (    h.preprocess_date < b.bod1_date
          OR (h.preprocess_date > b.bod1_date AND h.preprocess_date <= SYSDATE))
    GROUP BY b.cuid, b.contract_code, b.username, b.appl_source, b.orig_offer_id, b.bod1_date
),

/* 10. Team / SUP */
emp AS (
    SELECT DISTINCT LOWER(username) AS username_lc, team, date_valid_from,
           NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h
    CROSS JOIN params p
    WHERE h.sup_name IS NOT NULL
      AND h.month >= TO_CHAR(p.date_from, 'YYYY-MM')
      AND h.month <= TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
),

/* 11. Cham diem */
evaluated AS (
    SELECT r.*,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
             THEN x.time_of_call_start_t0 END AS time_of_call_start_t0,
        mc.contract_call_type,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_contract_raw END AS next_apply_contract,
        v.next_apply_date,
        CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_status_raw   END AS name_credit_status,
        CASE WHEN x.time_of_call_start_t0 < r.time_of_call_start
              AND r.time_of_call_start - x.time_of_call_start_t0 <= 14
             THEN 1 ELSE 0 END AS result_step_1,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_contract_raw  END AS prev_contract,
        v.prev_bod1_date,
        v.hidden_prev_contract,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_bod1_user_raw END AS prev_bod1_user,
        CASE WHEN v.prev_bod1_date IS NOT NULL THEN v.prev_status_raw    END AS prev_credit_status,
        CASE
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')                  THEN 1
            WHEN NVL(r.bod1_user, '#') <> r.username                 THEN 0
            WHEN v.prev_bod1_date IS NULL                                         THEN 1
            WHEN v.prev_bod1_user_raw = r.username                  THEN 1
            WHEN r.bod1_date - v.prev_bod1_date <= 14                             THEN 0
            ELSE 1
        END AS result_step_3,
        CASE
            WHEN mc.contract_call_type IN ('Inbound', 'Outbound')
                THEN 'HD tu ' || mc.contract_call_type || ' -> khong xet 14 ngay'
            WHEN NVL(r.bod1_user, '#') <> r.username
                THEN 'Ops khong len BOD1 (BOD1 boi ' || NVL(r.bod1_user, 'N/A') || ')'
            WHEN v.prev_bod1_date IS NULL
                THEN 'Khong co HD truoc tren dashboard'
                     || CASE WHEN v.hidden_prev_contract IS NOT NULL
                             THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
            WHEN v.prev_bod1_user_raw = r.username
                THEN 'HD truoc ' || v.prev_contract_raw || ' cung Ops'
            WHEN r.bod1_date - v.prev_bod1_date <= 14
                THEN 'HD truoc ' || v.prev_contract_raw || ' boi ' || NVL(v.prev_bod1_user_raw, 'N/A')
                     || ' (' || v.prev_status_raw || ') cach '
                     || CASE WHEN r.bod1_date - v.prev_bod1_date < 1
                             THEN TO_CHAR(ROUND((r.bod1_date - v.prev_bod1_date) * 24, 1)) || ' gio'
                             ELSE TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay' END
                     || ' <= 14 ngay'
            ELSE 'HD truoc ' || v.prev_contract_raw || ' boi Ops khac, cach '
                 || TO_CHAR(ROUND(r.bod1_date - v.prev_bod1_date, 1)) || ' ngay > 14'
                 || CASE WHEN v.hidden_prev_contract IS NOT NULL
                         THEN ' (bo qua HD an ' || v.hidden_prev_contract || ')' END
        END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0 x ON x.cuid = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.username = r.username
                             AND mc.appl_source = r.appl_source AND mc.orig_offer_id = r.orig_offer_id
                             AND mc.bod_date = r.bod_date
    LEFT JOIN hist_context v ON v.cuid = r.cuid AND v.contract_code = r.contract_code AND v.username = r.username
                           AND v.appl_source = r.appl_source AND v.orig_offer_id = r.orig_offer_id
                           AND v.bod1_date = r.bod1_date
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                                   AS call_uuid,
    r.username,
    e.team,
    h.sup_name                                                AS sup,
    r.contract_call_type,
    r.call_type,
    r.time_of_call_start_t0,
    r.time_of_call_start                                      AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                               AS report_date,
    ROUND(r.time_of_call_start - r.time_of_call_start_t0, 2)  AS t_diff_t0,
    r.contract_code                                           AS first_apply_contract,
    r.appl_source,
    r.qc07_visible,  -- co mo phong, khong phai danh sach QC07 da xac nhan
    r.contract_scope,
    r.contract_bod_date,
    r.contract_status,
    r.bod1_date,
    r.bod1_user,
    r.bod2_date,
    r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)               AS follow_dates,
    ROUND(r.time_of_call_start - r.bod1_date, 2) AS days_since_bod1,
    ROUND(r.time_of_call_start - r.bod2_date, 2) AS days_since_bod2,
    r.next_apply_contract,
    r.next_apply_date,
    r.name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract,
    r.prev_bod1_date,
    r.prev_bod1_user,
    r.prev_credit_status,
    r.hidden_prev_contract,                                   -- HD an tren QC07 trong 14 ngay, bi bo qua o Step 3
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                                    AS final_result
FROM evaluated r
LEFT JOIN emp e ON e.username_lc = LOWER(r.username)
               AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to
LEFT JOIN hr  h ON h.op_username = r.username
               AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM')
-- WHERE r.time_of_call_start - r.bod2_date > 180
ORDER BY r.cuid, r.bod1_date, r.contract_code;
-----------------------------







/* =====================================================================
   QC07 FOLLOW TRACKING - COMPACT (Power BI) - 14/10/2026
   Period : T calls in last 3 months (+14 days back for T0)
   Grain  : 1 row per CUID + contract + source (latest T across Ops)
   Mapping: same CUID + offer, contract VISIBLE on QC07 only
            (latest per source x CUID x offer, BOD1 in period)
   T      : latest Manual Outbound / Personal Callback
   T0     : earliest Inbound / Outbound before T (same CUID + Ops)
   Step 1 : T - T0 <= 14 days -> 1, else 0
   Step 2 : T - BOD1 <= 30 OR T - BOD2 <= 180 (no Ops check, BOD after T allowed)
   Step 3 : contract from IB/OB -> 1; caller did not do BOD1 -> 0;
            previous QC07-visible contract: none / same Ops -> 1,
            other Ops <= 14 days -> 0, > 14 days -> 1
   Final  : Step 3 = 1 AND (Step 1 = 1 OR Step 2 = 1)
   ===================================================================== */
WITH params AS (
    SELECT TRUNC(SYSDATE)                      AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)      AS date_from,
           TRUNC(SYSDATE) + 1                  AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14 AS date_from_t0
    FROM dual
),

/* 1. Calls in period (+14 days for T0), only needed columns */
call_raw AS (
    SELECT /*+ MATERIALIZE PARALLEL(sas, 8) */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid, sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                 THEN 'Personal Callback'
             WHEN sas.type_tls_call = 'OB_Man'
              AND sas.target_object_selected NOT LIKE '%INBOUND%'
              AND sas.interaction_type_key = 3
                 THEN 'Manual Outbound'
             ELSE sas.call_type END AS call_type
    FROM ap_tls.tb_tls_call_sas sas, params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (sas.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                           'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
           OR sas.call_type IN ('Inbound','Outbound'))
--    AND sas.cuid IN ('7983363','7395011','10823694')   -- TEST only
),

/* 2. Calls shown on QC07 */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
           COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c, params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                        'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. De-duplicate SAS grain (QC07 priority), keep T calls, latest per CUID + offer + Ops */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re, params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX','CCX','CC_CC','ACLX','ACLLG','XNA','SAI','ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT cuid_num FROM calls_qc WHERE grain_count > 1)
),
t_calls AS (
    SELECT /*+ MATERIALIZE */ cuid, cuid_num, username, orig_offer_id, call_id,
           media_server_ixn_guid, call_type, time_of_call_start
    FROM (
        SELECT d.*,
               ROW_NUMBER() OVER (PARTITION BY d.cuid_num, d.orig_offer_id, d.username
                                  ORDER BY d.time_of_call_start DESC, d.call_id DESC) AS rn_t
        FROM (
            SELECT c.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
                       ORDER BY CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END NULLS LAST,
                                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END NULLS LAST,
                                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END NULLS LAST
                   ) AS rn_grain
            FROM calls_qc c
            LEFT JOIN scoring sc ON c.grain_count > 1 AND sc.id_cuid = c.cuid_num
        ) d
        WHERE d.rn_grain = 1
          AND d.call_type IN ('Manual Outbound', 'Personal Callback')
    )
    WHERE rn_t = 1
),

/* 4. Contracts of CUIDs with T, from date_from_t0 (enough for mapping, Step 3, next).
      rn = 1 -> latest contract per source x CUID x offer (QC07 rule) */
contract AS (
    SELECT /*+ MATERIALIZE */ u.*,
           ROW_NUMBER() OVER (PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                              ORDER BY u.preprocess_date DESC, u.contract_code DESC) AS rn
    FROM (
        SELECT cuid, contract_code, orig_offer_id, preprocess_date, preprocess_user,
               process_date, process_user, name_credit_status, 'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx
        UNION ALL
        SELECT cuid, contract_code, orig_offer_id, preprocess_date, preprocess_user,
               process_date, process_user, name_credit_status, 'CCX'
        FROM ap_tls.tb_tls_appl_ccx
    ) u, params p
    WHERE u.preprocess_date >= p.date_from_t0
      AND u.cuid IN (SELECT cuid_num FROM t_calls)
),

/* 5. Map T -> QC07-visible contract (same CUID + offer); latest T across Ops */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT s.*,
               a.contract_code, a.appl_source, a.name_credit_status AS contract_status,
               a.preprocess_date AS bod1_date, a.preprocess_user AS bod1_user,
               a.process_date    AS bod2_date, a.process_user    AS bod2_user,
               CASE WHEN a.process_date IS NOT NULL THEN 'BOD2' ELSE 'BOD1' END AS stage,
               NVL(a.process_date, a.preprocess_date)                          AS bod_date,
               CASE WHEN s.time_of_call_start - a.preprocess_date <= 30
                      OR s.time_of_call_start - a.process_date    <= 180
                    THEN 1 ELSE 0 END AS result_step_2,
               ROW_NUMBER() OVER (PARTITION BY s.cuid, a.contract_code, a.appl_source
                                  ORDER BY s.time_of_call_start DESC, s.call_id DESC, s.username) AS rn_f
        FROM t_calls s
        JOIN contract a
          ON a.cuid = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         AND a.rn = 1
        CROSS JOIN params p
        WHERE a.preprocess_date >= p.date_from          -- QC07 visible: BOD1 in period
    ) WHERE rn_f = 1
),

/* 6. T0 = earliest IB/OB per CUID + Ops */
t0 AS (
    SELECT cuid, username, MIN(time_of_call_start) AS t0_time
    FROM call_raw x
    WHERE call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls f WHERE f.cuid = x.cuid AND f.username = x.username)
    GROUP BY cuid, username
),

/* 7. Call type of caller closest to BOD time (BOD always in period -> calls_qc is enough) */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.appl_source,
           MIN(c.call_type) KEEP (DENSE_RANK FIRST ORDER BY
               CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
               c.time_of_call_start DESC, c.call_id DESC) AS contract_call_type
    FROM follow_calls f
    JOIN calls_qc c
      ON c.cuid = f.cuid AND c.username = f.username AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.appl_source
),

/* 8. Previous contract (QC07-visible only) + next contract (all) */
qc_offers AS (
    SELECT /*+ MATERIALIZE */ DISTINCT cuid_num, orig_offer_id FROM calls_qc
),
hist AS (
    SELECT a.*,
           CASE WHEN a.rn = 1
                 AND EXISTS (SELECT 1 FROM qc_offers q
                             WHERE q.cuid_num = a.cuid AND q.orig_offer_id = a.orig_offer_id)
                THEN 1 ELSE 0 END AS dash_visible
    FROM contract a
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.appl_source,
        MAX(h.prev_key)                                                                                     AS prev_bod1_date,
        MAX(h.contract_code)      KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_contract,
        MAX(h.preprocess_user)    KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_bod1_user,
        MAX(h.name_credit_status) KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_credit_status,
        MAX(h.hidden_key)                                                                                   AS hidden_prev_contract,
        MIN(h.next_key)                                                                                     AS next_apply_date,
        MIN(h.contract_code)      KEEP (DENSE_RANK FIRST ORDER BY h.next_key NULLS LAST, h.contract_code)  AS next_apply_contract,
        MIN(h.name_credit_status) KEEP (DENSE_RANK FIRST ORDER BY h.next_key NULLS LAST, h.contract_code)  AS next_credit_status
    FROM follow_calls b
    CROSS APPLY (
        SELECT x.contract_code, x.preprocess_user, x.name_credit_status,
               CASE WHEN x.preprocess_date < b.bod1_date AND x.dash_visible = 1
                    THEN x.preprocess_date END AS prev_key,
               CASE WHEN x.preprocess_date < b.bod1_date AND x.preprocess_date >= b.bod1_date - 14
                     AND x.dash_visible = 0 THEN x.contract_code END AS hidden_key,
               CASE WHEN x.preprocess_date > b.bod1_date AND x.preprocess_date <= SYSDATE
                    THEN x.preprocess_date END AS next_key
        FROM hist x
        WHERE x.cuid = b.cuid_num
          AND x.contract_code <> b.contract_code
    ) h
    GROUP BY b.cuid, b.contract_code, b.appl_source
),

/* 9. Scoring */
evaluated AS (
    SELECT r.*, mc.contract_call_type,
           CASE WHEN x.t0_time < r.time_of_call_start THEN x.t0_time END AS t0_time,
           v.prev_bod1_date, v.hidden_prev_contract, v.next_apply_date,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_contract       END AS prev_contract,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_bod1_user      END AS prev_bod1_user,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_credit_status  END AS prev_credit_status,
           CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_apply_contract END AS next_apply_contract,
           CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_credit_status  END AS next_credit_status,
           CASE WHEN x.t0_time < r.time_of_call_start
                 AND r.time_of_call_start - x.t0_time <= 14 THEN 1 ELSE 0 END AS result_step_1,
           CASE WHEN mc.contract_call_type IN ('Inbound','Outbound') THEN 1
                WHEN NVL(r.bod1_user, '#') <> r.username             THEN 0
                WHEN v.prev_bod1_date IS NULL                        THEN 1
                WHEN v.prev_bod1_user = r.username                   THEN 1
                WHEN r.bod1_date - v.prev_bod1_date <= 14            THEN 0
                ELSE 1 END AS result_step_3,
           CASE WHEN mc.contract_call_type IN ('Inbound','Outbound') THEN 'HD tu IB/OB'
                WHEN NVL(r.bod1_user, '#') <> r.username             THEN 'Ops khong len BOD1'
                WHEN v.prev_bod1_date IS NULL                        THEN 'Khong co HD truoc'
                WHEN v.prev_bod1_user = r.username                   THEN 'HD truoc cung Ops'
                WHEN r.bod1_date - v.prev_bod1_date <= 14            THEN 'HD truoc Ops khac <= 14 ngay'
                ELSE 'HD truoc Ops khac > 14 ngay' END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0            x  ON x.cuid  = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.appl_source = r.appl_source
    LEFT JOIN hist_context  v  ON v.cuid  = r.cuid AND v.contract_code  = r.contract_code AND v.appl_source  = r.appl_source
),

/* 10. Team (1 value per row) / SUP */
emp AS (
    SELECT username, team, date_valid_from, NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h, params p
    WHERE h.sup_name IS NOT NULL
      AND h.month BETWEEN TO_CHAR(p.date_from, 'YYYY-MM') AND TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                              AS call_uuid,
    r.username,
    (SELECT MAX(e.team) KEEP (DENSE_RANK LAST ORDER BY e.date_valid_from)
       FROM emp e
      WHERE e.username = r.username
        AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to) AS team,
    h.sup_name                                           AS sup,
    r.contract_call_type,
    r.call_type,
    r.t0_time                                            AS time_of_call_start_t0,
    r.time_of_call_start                                 AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                          AS report_date,
    ROUND(r.time_of_call_start - r.t0_time, 2)           AS t_diff_t0,
    r.contract_code                                      AS first_apply_contract,
    r.appl_source,
    r.contract_status,
    r.bod1_date, r.bod1_user, r.bod2_date, r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)          AS follow_dates,
    ROUND(r.time_of_call_start - r.bod1_date, 2)         AS days_since_bod1,
    ROUND(r.time_of_call_start - r.bod2_date, 2)         AS days_since_bod2,
    r.next_apply_contract,
    r.next_apply_date,
    r.next_credit_status                                 AS name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract, r.prev_bod1_date, r.prev_bod1_user, r.prev_credit_status,
    r.hidden_prev_contract,
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                               AS final_result
FROM evaluated r
LEFT JOIN hr h ON h.op_username = r.username
              AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM');









-----------------
/* =====================================================================
   QC07 FOLLOW TRACKING - COMPACT (Power BI) - 14/10/2026
   Period : T calls in last 1 month (+14 days back for T0)
   Old contracts: BOD1 up to contract_lookback_days (365) before period start,
            so Step 2 can be 0 (BOD1 > 30 days AND BOD2 > 180 days)
   Grain  : 1 row per CUID + contract + source (latest T across Ops)
   Mapping: same CUID + offer, latest contract per source x CUID x offer
            (QC07 rank rule), NO period limit on BOD1 -> old contracts included
   T      : latest Manual Outbound / Personal Callback
   T0     : earliest Inbound / Outbound before T (same CUID + Ops)
   Step 1 : T - T0 <= 14 days -> 1, else 0
   Step 2 : T - BOD1 <= 30 OR T - BOD2 <= 180 (no Ops check, BOD after T allowed)
   Step 3 : contract from IB/OB -> 1; caller did not do BOD1 -> 0;
            previous QC07-visible contract: none / same Ops -> 1,
            other Ops <= 14 days -> 0, > 14 days -> 1
   Final  : Step 3 = 1 AND (Step 1 = 1 OR Step 2 = 1)
   ===================================================================== */
WITH params AS (
    SELECT TRUNC(SYSDATE)                      AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)      AS date_from,
           TRUNC(SYSDATE) + 1                  AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14 AS date_from_t0,
           365                                 AS contract_lookback_days   -- how old a contract can be
    FROM dual
),

/* 1. Calls in period (+14 days for T0), only needed columns */
call_raw AS (
    SELECT /*+ MATERIALIZE PARALLEL(sas, 8) */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid, sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                 THEN 'Personal Callback'
             WHEN sas.type_tls_call = 'OB_Man'
              AND sas.target_object_selected NOT LIKE '%INBOUND%'
              AND sas.interaction_type_key = 3
                 THEN 'Manual Outbound'
             ELSE sas.call_type END AS call_type
    FROM ap_tls.tb_tls_call_sas sas, params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (sas.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                           'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
           OR sas.call_type IN ('Inbound','Outbound'))
    AND sas.cuid IN ('7983363','7395011','10823694','31718034')   -- TEST only
),

/* 2. Calls shown on QC07 */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
           COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c, params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                        'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. De-duplicate SAS grain (QC07 priority), keep T calls, latest per CUID + offer + Ops */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re, params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX','CCX','CC_CC','ACLX','ACLLG','XNA','SAI','ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT cuid_num FROM calls_qc WHERE grain_count > 1)
),
t_calls AS (
    SELECT /*+ MATERIALIZE */ cuid, cuid_num, username, orig_offer_id, call_id,
           media_server_ixn_guid, call_type, time_of_call_start
    FROM (
        SELECT d.*,
               ROW_NUMBER() OVER (PARTITION BY d.cuid_num, d.orig_offer_id, d.username
                                  ORDER BY d.time_of_call_start DESC, d.call_id DESC) AS rn_t
        FROM (
            SELECT c.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
                       ORDER BY CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END NULLS LAST,
                                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END NULLS LAST,
                                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END NULLS LAST
                   ) AS rn_grain
            FROM calls_qc c
            LEFT JOIN scoring sc ON c.grain_count > 1 AND sc.id_cuid = c.cuid_num
        ) d
        WHERE d.rn_grain = 1
          AND d.call_type IN ('Manual Outbound', 'Personal Callback')
    )
    WHERE rn_t = 1
),

/* 4. Contracts of CUIDs with T, BOD1 within lookback (old contracts included).
      rn = 1 -> latest contract per source x CUID x offer (QC07 rule) */
contract AS (
    SELECT /*+ MATERIALIZE */ u.*,
           ROW_NUMBER() OVER (PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                              ORDER BY u.preprocess_date DESC, u.contract_code DESC) AS rn
    FROM (
        SELECT cuid, contract_code, orig_offer_id, preprocess_date, preprocess_user,
               process_date, process_user, name_credit_status, 'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx
        UNION ALL
        SELECT cuid, contract_code, orig_offer_id, preprocess_date, preprocess_user,
               process_date, process_user, name_credit_status, 'CCX'
        FROM ap_tls.tb_tls_appl_ccx
    ) u, params p
    WHERE u.preprocess_date >= p.date_from - p.contract_lookback_days
      AND u.cuid IN (SELECT cuid_num FROM t_calls)
),

/* 5. Map T -> latest contract of the offer (any BOD1 date); latest T across Ops */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT s.*,
               a.contract_code, a.appl_source, a.name_credit_status AS contract_status,
               a.preprocess_date AS bod1_date, a.preprocess_user AS bod1_user,
               a.process_date    AS bod2_date, a.process_user    AS bod2_user,
               CASE WHEN a.process_date IS NOT NULL THEN 'BOD2' ELSE 'BOD1' END AS stage,
               NVL(a.process_date, a.preprocess_date)                          AS bod_date,
               CASE WHEN s.time_of_call_start - a.preprocess_date <= 30
                      OR s.time_of_call_start - a.process_date    <= 180
                    THEN 1 ELSE 0 END AS result_step_2,
               ROW_NUMBER() OVER (PARTITION BY s.cuid, a.contract_code, a.appl_source
                                  ORDER BY s.time_of_call_start DESC, s.call_id DESC, s.username) AS rn_f
        FROM t_calls s
        JOIN contract a
          ON a.cuid = s.cuid_num
         AND a.orig_offer_id = s.orig_offer_id
         AND a.rn = 1
    ) WHERE rn_f = 1
),

/* 6. T0 = earliest IB/OB per CUID + Ops */
t0 AS (
    SELECT cuid, username, MIN(time_of_call_start) AS t0_time
    FROM call_raw x
    WHERE call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls f WHERE f.cuid = x.cuid AND f.username = x.username)
    GROUP BY cuid, username
),

/* 7. Call type of caller closest to BOD time.
      BOD in period -> calls_qc; BOD before period -> read SAS around BOD day only */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.appl_source,
           MIN(c.call_type) KEEP (DENSE_RANK FIRST ORDER BY
               CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
               c.time_of_call_start DESC, c.call_id DESC) AS contract_call_type
    FROM follow_calls f
    JOIN calls_qc c
      ON c.cuid = f.cuid AND c.username = f.username AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    GROUP BY f.cuid, f.contract_code, f.appl_source
    UNION ALL
    SELECT f.cuid, f.contract_code, f.appl_source,
           MIN(CASE WHEN c.call_type = 'Outbound' AND c.record_type = 'Personal Callback'
                        THEN 'Personal Callback'
                    WHEN c.type_tls_call = 'OB_Man'
                     AND c.target_object_selected NOT LIKE '%INBOUND%'
                     AND c.interaction_type_key = 3
                        THEN 'Manual Outbound'
                    ELSE c.call_type END)
           KEEP (DENSE_RANK FIRST ORDER BY
               CASE WHEN f.bod_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
               c.time_of_call_start DESC, c.call_id DESC)
    FROM follow_calls f
    CROSS JOIN params p
    JOIN ap_tls.tb_tls_call_sas c
      ON c.cuid = f.cuid AND c.username = f.username AND c.orig_offer_id = f.orig_offer_id
     AND c.time_of_call_start >= TRUNC(f.bod_date) - 1          -- only around BOD day (fast)
     AND c.time_of_call_start <= f.bod_date
     AND (c.time_of_call_end >= f.bod_date OR c.time_of_call_start >= TRUNC(f.bod_date))
    WHERE f.bod_date < p.date_from
      AND c.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                        'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type = 'Outbound' AND c.name_camp_call IS NULL))
    GROUP BY f.cuid, f.contract_code, f.appl_source
),

/* 8. Previous contract (QC07-visible only) + next contract (all) */
qc_offers AS (
    SELECT /*+ MATERIALIZE */ DISTINCT cuid_num, orig_offer_id FROM calls_qc
),
hist AS (
    SELECT a.*,
           CASE WHEN a.rn = 1
                 AND EXISTS (SELECT 1 FROM qc_offers q
                             WHERE q.cuid_num = a.cuid AND q.orig_offer_id = a.orig_offer_id)
                THEN 1 ELSE 0 END AS dash_visible
    FROM contract a
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.appl_source,
        MAX(h.prev_key)                                                                                     AS prev_bod1_date,
        MAX(h.contract_code)      KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_contract,
        MAX(h.preprocess_user)    KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_bod1_user,
        MAX(h.name_credit_status) KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_credit_status,
        MAX(h.hidden_key)                                                                                   AS hidden_prev_contract,
        MIN(h.next_key)                                                                                     AS next_apply_date,
        MIN(h.contract_code)      KEEP (DENSE_RANK FIRST ORDER BY h.next_key NULLS LAST, h.contract_code)  AS next_apply_contract,
        MIN(h.name_credit_status) KEEP (DENSE_RANK FIRST ORDER BY h.next_key NULLS LAST, h.contract_code)  AS next_credit_status
    FROM follow_calls b
    CROSS APPLY (
        SELECT x.contract_code, x.preprocess_user, x.name_credit_status,
               CASE WHEN x.preprocess_date < b.bod1_date AND x.dash_visible = 1
                    THEN x.preprocess_date END AS prev_key,
               CASE WHEN x.preprocess_date < b.bod1_date AND x.preprocess_date >= b.bod1_date - 14
                     AND x.dash_visible = 0 THEN x.contract_code END AS hidden_key,
               CASE WHEN x.preprocess_date > b.bod1_date AND x.preprocess_date <= SYSDATE
                    THEN x.preprocess_date END AS next_key
        FROM hist x
        WHERE x.cuid = b.cuid_num
          AND x.contract_code <> b.contract_code
    ) h
    GROUP BY b.cuid, b.contract_code, b.appl_source
),

/* 9. Scoring */
evaluated AS (
    SELECT r.*, mc.contract_call_type,
           CASE WHEN x.t0_time < r.time_of_call_start THEN x.t0_time END AS t0_time,
           v.prev_bod1_date, v.hidden_prev_contract, v.next_apply_date,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_contract       END AS prev_contract,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_bod1_user      END AS prev_bod1_user,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_credit_status  END AS prev_credit_status,
           CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_apply_contract END AS next_apply_contract,
           CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_credit_status  END AS next_credit_status,
           CASE WHEN x.t0_time < r.time_of_call_start
                 AND r.time_of_call_start - x.t0_time <= 14 THEN 1 ELSE 0 END AS result_step_1,
           CASE WHEN mc.contract_call_type IN ('Inbound','Outbound') THEN 1
                WHEN NVL(r.bod1_user, '#') <> r.username             THEN 0
                WHEN v.prev_bod1_date IS NULL                        THEN 1
                WHEN v.prev_bod1_user = r.username                   THEN 1
                WHEN r.bod1_date - v.prev_bod1_date <= 14            THEN 0
                ELSE 1 END AS result_step_3,
           CASE WHEN mc.contract_call_type IN ('Inbound','Outbound') THEN 'HD tu IB/OB'
                WHEN NVL(r.bod1_user, '#') <> r.username             THEN 'Ops khong len BOD1'
                WHEN v.prev_bod1_date IS NULL                        THEN 'Khong co HD truoc'
                WHEN v.prev_bod1_user = r.username                   THEN 'HD truoc cung Ops'
                WHEN r.bod1_date - v.prev_bod1_date <= 14            THEN 'HD truoc Ops khac <= 14 ngay'
                ELSE 'HD truoc Ops khac > 14 ngay' END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0            x  ON x.cuid  = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.appl_source = r.appl_source
    LEFT JOIN hist_context  v  ON v.cuid  = r.cuid AND v.contract_code  = r.contract_code AND v.appl_source  = r.appl_source
),

/* 10. Team (1 value per row) / SUP */
emp AS (
    SELECT username, team, date_valid_from, NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h, params p
    WHERE h.sup_name IS NOT NULL
      AND h.month BETWEEN TO_CHAR(p.date_from, 'YYYY-MM') AND TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                              AS call_uuid,
    r.username,
    (SELECT MAX(e.team) KEEP (DENSE_RANK LAST ORDER BY e.date_valid_from)
       FROM emp e
      WHERE e.username = r.username
        AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to) AS team,
    h.sup_name                                           AS sup,
    r.contract_call_type,
    r.call_type,
    r.t0_time                                            AS time_of_call_start_t0,
    r.time_of_call_start                                 AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                          AS report_date,
    ROUND(r.time_of_call_start - r.t0_time, 2)           AS t_diff_t0,
    r.contract_code                                      AS first_apply_contract,
    r.appl_source,
    r.contract_status,
    r.bod1_date, r.bod1_user, r.bod2_date, r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)          AS follow_dates,
    ROUND(r.time_of_call_start - r.bod1_date, 2)         AS days_since_bod1,
    ROUND(r.time_of_call_start - r.bod2_date, 2)         AS days_since_bod2,
    r.next_apply_contract,
    r.next_apply_date,
    r.next_credit_status                                 AS name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract, r.prev_bod1_date, r.prev_bod1_user, r.prev_credit_status,
    r.hidden_prev_contract,
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                               AS final_result
FROM evaluated r
LEFT JOIN hr h ON h.op_username = r.username
              AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM');











-----------16/10/2026
WITH params AS (
    SELECT TRUNC(SYSDATE)                      AS run_date,
           ADD_MONTHS(TRUNC(SYSDATE), -1)      AS date_from,
           TRUNC(SYSDATE) + 1                  AS date_to,
           ADD_MONTHS(TRUNC(SYSDATE), -1) - 14 AS date_from_t0,
           365                                 AS contract_lookback_days   -- how old a contract can be
    FROM dual
),

/* 1. Calls in period (+14 days for T0), only needed columns */
call_raw AS (
    SELECT /*+ MATERIALIZE PARALLEL(sas, 8) */
        sas.call_id, sas.resource_role, sas.interaction_resource_ordinal,
        sas.call_uuid, sas.media_server_ixn_guid, sas.cuid,
        TO_NUMBER(sas.cuid DEFAULT NULL ON CONVERSION ERROR) AS cuid_num,
        sas.username, sas.orig_offer_id,
        sas.time_of_call_start, sas.time_of_call_end,
        sas.durations, sas.channel, sas.name_camp_call,
        sas.call_type AS call_type_raw,
        CASE WHEN sas.call_type = 'Outbound' AND sas.record_type = 'Personal Callback'
                 THEN 'Personal Callback'
             WHEN sas.type_tls_call = 'OB_Man'
              AND sas.target_object_selected NOT LIKE '%INBOUND%'
              AND sas.interaction_type_key = 3
                 THEN 'Manual Outbound'
             ELSE sas.call_type END AS call_type
    FROM ap_tls.tb_tls_call_sas sas, params p
    WHERE sas.time_of_call_start >= p.date_from_t0
      AND sas.time_of_call_start <  p.date_to
      AND (sas.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                           'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
           OR sas.call_type IN ('Inbound','Outbound'))
--    AND sas.cuid IN ('7983363','7395011','10823694','31718034','31624790')   -- TEST only
),

/* 2. Calls shown on QC07 */
calls_qc AS (
    SELECT /*+ MATERIALIZE */ c.*,
           COUNT(*) OVER (PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal) AS grain_count
    FROM call_raw c, params p
    WHERE c.time_of_call_start >= p.date_from
      AND c.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                        'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type_raw = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type_raw = 'Outbound' AND c.name_camp_call IS NULL))
),

/* 3. De-duplicate SAS grain (QC07 priority), keep T calls, latest per CUID + offer + Ops */
scoring AS (
    SELECT DISTINCT re.id_cuid, re.apl_bod0_dtm
    FROM ap_tls.tb_tls_orbp re, params p
    WHERE re.apl_bod0_dtm >= p.run_date - 90
      AND re.apl_bod0_offer_type IN ('CLX','CCX','CC_CC','ACLX','ACLLG','XNA','SAI','ES')
      AND re.apl_f_bod0_otp IN (1, 2)
      AND re.id_cuid IN (SELECT cuid_num FROM calls_qc WHERE grain_count > 1)
),
t_calls AS (
    SELECT /*+ MATERIALIZE */ cuid, cuid_num, username, orig_offer_id, call_id,
           media_server_ixn_guid, call_type, time_of_call_start
    FROM (
        SELECT d.*,
               ROW_NUMBER() OVER (PARTITION BY d.cuid_num, d.orig_offer_id, d.username
                                  ORDER BY d.time_of_call_start DESC, d.call_id DESC) AS rn_t
        FROM (
            SELECT c.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY c.call_id, c.resource_role, c.interaction_resource_ordinal
                       ORDER BY CASE WHEN sc.apl_bod0_dtm BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 1
                                     WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN 2
                                     WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN 3 END NULLS LAST,
                                CASE WHEN sc.apl_bod0_dtm < c.time_of_call_start THEN sc.apl_bod0_dtm END NULLS LAST,
                                CASE WHEN sc.apl_bod0_dtm > c.time_of_call_end   THEN sc.apl_bod0_dtm END NULLS LAST
                   ) AS rn_grain
            FROM calls_qc c
            LEFT JOIN scoring sc ON c.grain_count > 1 AND sc.id_cuid = c.cuid_num
        ) d
        WHERE d.rn_grain = 1
          AND d.call_type IN ('Manual Outbound', 'Personal Callback')
    )
    WHERE rn_t = 1
),

/* 4. Contracts of CUIDs with T, BOD1 within lookback (old contracts included).
      rn is used ONLY for previous-contract QC07 visibility */
contract AS (
    SELECT /*+ MATERIALIZE */ u.*,
           ROW_NUMBER() OVER (PARTITION BY u.appl_source, u.cuid, u.orig_offer_id
                              ORDER BY u.preprocess_date DESC, u.contract_code DESC) AS rn
    FROM (
        SELECT cuid, contract_code, orig_offer_id, preprocess_date, preprocess_user,
               process_date, process_user, name_credit_status, 'CLX' AS appl_source
        FROM ap_tls.tb_tls_appl_clx
        UNION ALL
        SELECT cuid, contract_code, orig_offer_id, preprocess_date, preprocess_user,
               process_date, process_user, name_credit_status, 'CCX'
        FROM ap_tls.tb_tls_appl_ccx
    ) u, params p
    WHERE u.preprocess_date >= p.date_from - p.contract_lookback_days
      AND u.preprocess_date < p.date_to
      AND u.cuid IN (SELECT cuid_num FROM t_calls)
),

/* 5. Confirmed offer matches + different-offer review candidates.
      Keep unmatched T calls. Only rank T; never discard a current contract by rn. */
follow_calls AS (
    SELECT /*+ MATERIALIZE */ * FROM (
        SELECT s.*,
               a.orig_offer_id AS contract_offer_id,
               CASE WHEN a.orig_offer_id = s.orig_offer_id THEN 1 ELSE 0 END AS offer_matched,
               a.contract_code, a.appl_source, a.name_credit_status AS contract_status,
               a.preprocess_date AS bod1_date, a.preprocess_user AS bod1_user,
               a.process_date AS bod2_date, a.process_user AS bod2_user,
               CASE WHEN a.process_user = s.username AND a.process_date IS NOT NULL THEN 'BOD2'
                    WHEN a.preprocess_user = s.username AND a.preprocess_date IS NOT NULL THEN 'BOD1'
               END AS stage,
               CASE WHEN a.process_user = s.username AND a.process_date IS NOT NULL THEN a.process_date
                    WHEN a.preprocess_user = s.username THEN a.preprocess_date
               END AS bod_date,
               CASE WHEN a.preprocess_user = s.username THEN a.preprocess_date
                    WHEN a.process_user = s.username THEN a.process_date
               END AS contract_call_date,
               CASE WHEN a.orig_offer_id = s.orig_offer_id THEN
                   CASE WHEN s.time_of_call_start - a.preprocess_date <= 30
                          OR s.time_of_call_start - a.process_date <= 180
                        THEN 1 ELSE 0 END
               END AS result_step_2,
               ROW_NUMBER() OVER (
                   PARTITION BY s.cuid, a.contract_code, a.appl_source, s.username,
                                CASE WHEN a.contract_code IS NULL THEN s.orig_offer_id END
                   ORDER BY CASE WHEN a.orig_offer_id = s.orig_offer_id THEN 0 ELSE 1 END,
                            s.time_of_call_start DESC, s.call_id DESC, s.username
               ) AS rn_f
        FROM t_calls s
        LEFT JOIN contract a
          ON a.cuid = s.cuid_num
         AND (
             a.orig_offer_id = s.orig_offer_id
             OR (
                 (a.orig_offer_id <> s.orig_offer_id
                  OR a.orig_offer_id IS NULL OR s.orig_offer_id IS NULL)
                 AND (
                     (a.preprocess_user = s.username
                      AND a.preprocess_date BETWEEN s.time_of_call_start - 180 AND s.time_of_call_start)
                     OR
                     (a.process_user = s.username
                      AND a.process_date BETWEEN s.time_of_call_start - 180 AND s.time_of_call_start)
                 )
             )
         )
    ) WHERE rn_f = 1
),

/* 6. T0 = earliest IB/OB per CUID + Ops */
t0 AS (
    SELECT cuid, username, MIN(time_of_call_start) AS t0_time
    FROM call_raw x
    WHERE call_type IN ('Inbound', 'Outbound')
      AND EXISTS (SELECT 1 FROM follow_calls f WHERE f.cuid = x.cuid AND f.username = x.username)
    GROUP BY cuid, username
),

/* 7. Call type of caller closest to BOD time.
      BOD in period -> calls_qc; BOD before period -> read SAS around BOD day only */
contract_call AS (
    SELECT f.cuid, f.contract_code, f.appl_source, f.username,
           MIN(c.call_type) KEEP (DENSE_RANK FIRST ORDER BY
               CASE WHEN f.contract_call_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
               c.time_of_call_start DESC, c.call_id DESC) AS contract_call_type
    FROM follow_calls f
    CROSS JOIN params p
    JOIN calls_qc c
      ON c.cuid = f.cuid AND c.username = f.username AND c.orig_offer_id = f.contract_offer_id
     AND f.offer_matched = 1
     AND c.time_of_call_start <= f.contract_call_date
     AND (c.time_of_call_end >= f.contract_call_date OR c.time_of_call_start >= TRUNC(f.contract_call_date))
    WHERE f.contract_call_date >= p.date_from
    GROUP BY f.cuid, f.contract_code, f.appl_source, f.username
    UNION ALL
    SELECT f.cuid, f.contract_code, f.appl_source, f.username,
           MIN(CASE WHEN c.call_type = 'Outbound' AND c.record_type = 'Personal Callback'
                        THEN 'Personal Callback'
                    WHEN c.type_tls_call = 'OB_Man'
                     AND c.target_object_selected NOT LIKE '%INBOUND%'
                     AND c.interaction_type_key = 3
                        THEN 'Manual Outbound'
                    ELSE c.call_type END)
           KEEP (DENSE_RANK FIRST ORDER BY
               CASE WHEN f.contract_call_date BETWEEN c.time_of_call_start AND c.time_of_call_end THEN 0 ELSE 1 END,
               c.time_of_call_start DESC, c.call_id DESC)
    FROM follow_calls f
    CROSS JOIN params p
    JOIN ap_tls.tb_tls_call_sas c
      ON c.cuid = f.cuid AND c.username = f.username AND c.orig_offer_id = f.contract_offer_id
     AND c.time_of_call_start >= TRUNC(f.contract_call_date) - 1          -- only around BOD day (fast)
     AND f.offer_matched = 1
     AND c.time_of_call_start <= f.contract_call_date
     AND (c.time_of_call_end >= f.contract_call_date OR c.time_of_call_start >= TRUNC(f.contract_call_date))
    WHERE f.contract_call_date < p.date_from
      AND c.channel IN ('CLX','ACLX','CCX','CCXP','SAI','ES',
                        'LEADER','TLS Business Excellence','SUP','QA-QC','QC')
      AND (   c.durations > 0
           OR (c.durations = 0 AND c.call_type = 'Inbound' AND c.call_uuid IS NOT NULL)
           OR (c.call_type = 'Outbound' AND c.name_camp_call IS NULL))
    GROUP BY f.cuid, f.contract_code, f.appl_source, f.username
),

/* 8. Previous contract (QC07-visible only) + next contract (all) */
qc_offers AS (
    SELECT /*+ MATERIALIZE */ DISTINCT c.cuid_num, c.orig_offer_id
    FROM calls_qc c CROSS JOIN params p
    WHERE c.time_of_call_start >= p.run_date - 30
),
hist AS (
    SELECT a.*,
           CASE WHEN a.rn = 1
                 AND a.preprocess_date >= (SELECT run_date - 30 FROM params)
                 AND EXISTS (SELECT 1 FROM qc_offers q
                             WHERE q.cuid_num = a.cuid AND q.orig_offer_id = a.orig_offer_id)
                THEN 1 ELSE 0 END AS dash_visible
    FROM contract a
),
hist_context AS (
    SELECT b.cuid, b.contract_code, b.appl_source, b.username,
        MAX(h.prev_key)                                                                                     AS prev_bod1_date,
        MAX(h.contract_code)      KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_contract,
        MAX(h.preprocess_user)    KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_bod1_user,
        MAX(h.name_credit_status) KEEP (DENSE_RANK LAST  ORDER BY h.prev_key NULLS FIRST, h.contract_code) AS prev_credit_status,
        MAX(h.hidden_key)                                                                                   AS hidden_prev_contract,
        MIN(h.next_key)                                                                                     AS next_apply_date,
        MIN(h.contract_code)      KEEP (DENSE_RANK FIRST ORDER BY h.next_key NULLS LAST, h.contract_code)  AS next_apply_contract,
        MIN(h.name_credit_status) KEEP (DENSE_RANK FIRST ORDER BY h.next_key NULLS LAST, h.contract_code)  AS next_credit_status
    FROM follow_calls b
    CROSS APPLY (
        SELECT x.contract_code, x.preprocess_user, x.name_credit_status,
               CASE WHEN x.preprocess_date < b.bod_date AND x.dash_visible = 1
                    THEN x.preprocess_date END AS prev_key,
               CASE WHEN x.preprocess_date < b.bod_date AND x.preprocess_date >= b.bod_date - 14
                     AND x.dash_visible = 0 THEN x.contract_code END AS hidden_key,
               CASE WHEN x.preprocess_date > b.bod1_date AND x.preprocess_date <= SYSDATE
                    THEN x.preprocess_date END AS next_key
        FROM hist x
        WHERE x.cuid = b.cuid_num
          AND x.contract_code <> b.contract_code
    ) h
    GROUP BY b.cuid, b.contract_code, b.appl_source, b.username
),

/* 9. Scoring */
evaluated AS (
    SELECT r.*, mc.contract_call_type,
           CASE WHEN x.t0_time < r.time_of_call_start THEN x.t0_time END AS t0_time,
           v.prev_bod1_date, v.hidden_prev_contract, v.next_apply_date,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_contract       END AS prev_contract,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_bod1_user      END AS prev_bod1_user,
           CASE WHEN v.prev_bod1_date  IS NOT NULL THEN v.prev_credit_status  END AS prev_credit_status,
           CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_apply_contract END AS next_apply_contract,
           CASE WHEN v.next_apply_date IS NOT NULL THEN v.next_credit_status  END AS next_credit_status,
           CASE WHEN x.t0_time < r.time_of_call_start
                 AND r.time_of_call_start - x.t0_time <= 14 THEN 1 ELSE 0 END AS result_step_1,
           CASE WHEN r.offer_matched = 0 THEN NULL
                WHEN mc.contract_call_type IS NULL THEN NULL
                WHEN mc.contract_call_type IN ('Inbound','Outbound') THEN 1
                WHEN r.bod_date IS NULL                              THEN NULL
                WHEN v.prev_bod1_date IS NULL                        THEN 1
                WHEN v.prev_bod1_user = r.username                   THEN 1
                WHEN r.bod_date - v.prev_bod1_date <= 14            THEN 0
                ELSE 1 END AS result_step_3,
           CASE WHEN r.contract_code IS NULL THEN 'Chua gan duoc hop dong'
                WHEN r.offer_matched = 0 THEN 'Chua xac minh call-HD: khac/thieu offer'
                WHEN mc.contract_call_type IS NULL THEN 'Chua xac dinh loai call tao HD'
                WHEN mc.contract_call_type IN ('Inbound','Outbound') THEN 'HD tu IB/OB'
                WHEN r.bod_date IS NULL                              THEN 'Chua xac dinh BOD cua Ops'
                WHEN v.prev_bod1_date IS NULL                        THEN 'Khong co HD truoc'
                WHEN v.prev_bod1_user = r.username                   THEN 'HD truoc cung Ops'
                WHEN r.bod_date - v.prev_bod1_date <= 14            THEN 'HD truoc Ops khac <= 14 ngay'
                ELSE 'HD truoc Ops khac > 14 ngay' END AS step3_reason
    FROM follow_calls r
    LEFT JOIN t0            x  ON x.cuid  = r.cuid AND x.username = r.username
    LEFT JOIN contract_call mc ON mc.cuid = r.cuid AND mc.contract_code = r.contract_code AND mc.appl_source = r.appl_source AND mc.username = r.username
    LEFT JOIN hist_context  v  ON v.cuid  = r.cuid AND v.contract_code  = r.contract_code AND v.appl_source  = r.appl_source AND v.username = r.username
),

/* 10. Team (1 value per row) / SUP */
emp AS (
    SELECT username, team, date_valid_from, NVL(date_valid_to, CURRENT_DATE) AS date_valid_to
    FROM ap_tls.tb_tls_employee
),
hr AS (
    SELECT h.op_username, h.month, MAX(h.sup_name) AS sup_name
    FROM ap_tls.hr_tls h, params p
    WHERE h.sup_name IS NOT NULL
      AND h.month BETWEEN TO_CHAR(p.date_from, 'YYYY-MM') AND TO_CHAR(p.run_date, 'YYYY-MM')
    GROUP BY h.op_username, h.month
    HAVING COUNT(DISTINCT h.sup_name) = 1
)

SELECT /*+ PARALLEL(16) */
    r.cuid,
    r.media_server_ixn_guid                              AS call_uuid,
    r.username,
    (SELECT MAX(e.team) KEEP (DENSE_RANK LAST ORDER BY e.date_valid_from)
       FROM emp e
      WHERE e.username = r.username
        AND TRUNC(r.time_of_call_start) BETWEEN e.date_valid_from AND e.date_valid_to) AS team,
    h.sup_name                                           AS sup,
    r.contract_call_type,
    r.call_type,
    r.t0_time                                            AS time_of_call_start_t0,
    r.time_of_call_start                                 AS time_of_call_start_t,
    TRUNC(r.time_of_call_start)                          AS report_date,
    ROUND(r.time_of_call_start - r.t0_time, 2)           AS t_diff_t0,
    r.contract_code                                      AS first_apply_contract,
    r.appl_source,
    r.contract_status,
    CASE WHEN r.bod1_user = r.username THEN r.bod1_date END       AS bod1_date,
    r.bod1_user,
    CASE WHEN r.bod2_user = r.username THEN r.bod2_date END       AS bod2_date,
    r.bod2_user,
    r.stage,
    r.bod_date,
    ROUND(r.time_of_call_start - r.bod_date, 2)          AS follow_dates,
    CASE WHEN r.bod1_user = r.username THEN ROUND(r.time_of_call_start - r.bod1_date, 2) END AS days_since_bod1,
    CASE WHEN r.bod2_user = r.username THEN ROUND(r.time_of_call_start - r.bod2_date, 2) END AS days_since_bod2,
    -- Raw previous-contract check; independent of the IB/OB Step3 exemption.
    CASE WHEN r.contract_code IS NULL OR r.offer_matched = 0 OR r.bod_date IS NULL THEN NULL
         WHEN r.prev_bod1_date IS NULL THEN 1
         WHEN r.prev_bod1_user = r.username THEN 1
         WHEN r.bod_date - r.prev_bod1_date <= 14 THEN 0
         ELSE 1 END                                     AS last_apply_14_day,
    r.next_apply_contract,
    r.next_apply_date,
    r.next_credit_status                                 AS name_credit_status,
    r.result_step_1,
    r.result_step_2,
    r.prev_contract, r.prev_bod1_date, r.prev_bod1_user, r.prev_credit_status,
    r.hidden_prev_contract,
    r.result_step_3,
    r.step3_reason,
    CASE WHEN r.result_step_3 IS NULL THEN NULL
         WHEN r.result_step_3 = 1 AND (r.result_step_1 = 1 OR r.result_step_2 = 1)
         THEN 1 ELSE 0 END                               AS final_result
FROM evaluated r
LEFT JOIN hr h ON h.op_username = r.username
              AND h.month = TO_CHAR(r.time_of_call_start, 'YYYY-MM')
WHERE r.contract_call_type is not null