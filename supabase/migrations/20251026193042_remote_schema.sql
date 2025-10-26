


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."comanda_tipo" AS ENUM (
    'compra',
    'venda'
);


ALTER TYPE "public"."comanda_tipo" OWNER TO "postgres";


CREATE TYPE "public"."pendencia_tipo" AS ENUM (
    'a_pagar',
    'a_receber'
);


ALTER TYPE "public"."pendencia_tipo" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."compra_por_material_periodo"("data_inicio" "date", "data_fim" "date") RETURNS TABLE("nome" "text", "kg" numeric, "gasto" numeric)
    LANGUAGE "sql"
    AS $$
  SELECT
    m.nome AS nome,
    COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4)   AS kg,
    COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS gasto
  FROM public.item i
  JOIN public.comanda c ON c.id = i.comanda
  JOIN public.material m ON m.id = i.material
  WHERE c.tipo = 'compra'::public.comanda_tipo
    AND i.data >= data_inicio::timestamptz
    AND i.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
  GROUP BY m.nome
  ORDER BY m.nome;
$$;


ALTER FUNCTION "public"."compra_por_material_periodo"("data_inicio" "date", "data_fim" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."compra_por_material_personalizado"("data_inicio" "date", "data_fim" "date") RETURNS TABLE("nome" "text", "kg" numeric, "total" numeric, "preco_medio" numeric)
    LANGUAGE "sql"
    AS $$
  SELECT
    m.nome AS nome,
    COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4) AS kg,
    COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS total,
    CASE 
      WHEN SUM(i.kg_total) > 0 
      THEN (SUM(i.valor_total) / SUM(i.kg_total))::NUMERIC(14,4)
      ELSE 0::NUMERIC(14,4)
    END AS preco_medio
  FROM item i
  JOIN comanda c ON c.id = i.comanda
  JOIN material m ON m.id = i.material
  WHERE c.tipo = 'compra'
    AND i.data BETWEEN data_inicio AND data_fim
  GROUP BY m.nome
  ORDER BY nome;
$$;


ALTER FUNCTION "public"."compra_por_material_personalizado"("data_inicio" "date", "data_fim" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_estoque_reset_apos_movimento"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_material_id bigint;
  v_tipo public.comanda_tipo;
  v_data timestamptz;
  v_reset_at timestamptz;
  v_kg_compra numeric;
  v_kg_venda  numeric;
  v_kg_antes  numeric;
BEGIN
  -- Material e data do movimento
  v_material_id := COALESCE(NEW.material, OLD.material);
  SELECT c.tipo, COALESCE(i.data, c.data)
    INTO v_tipo, v_data
  FROM public.item i
  JOIN public.comanda c ON c.id = i.comanda
  WHERE i.id = COALESCE(NEW.id, OLD.id);

  -- Ponto de reset atual (se não existir, epoch)
  SELECT COALESCE(er.reset_at, to_timestamp(0))
    INTO v_reset_at
  FROM public.estoque_reset er
  WHERE er.material_id = v_material_id;

  -- Estoque acumulado desde o último reset (ANTES deste novo movimento)
  -- (exclui o próprio NEW quando for INSERT/UPDATE)
  SELECT
    COALESCE(SUM(CASE WHEN c.tipo = 'compra' THEN i.kg_total ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN c.tipo = 'venda'  THEN i.kg_total ELSE 0 END), 0)
  INTO v_kg_compra, v_kg_venda
  FROM public.item i
  JOIN public.comanda c ON c.id = i.comanda
  WHERE i.material = v_material_id
    AND i.data >= v_reset_at
    AND (NEW.id IS NULL OR i.id <> NEW.id);  -- exclui o registro novo ao calcular “antes”

  v_kg_antes := v_kg_compra - v_kg_venda;

  -- Se este movimento é uma VENDA e após aplicar o NEW o estoque zeria ou fica negativo,
  -- registramos o reset_at para "após" este movimento (exclui a venda que zerou do novo ciclo).
  IF TG_OP IN ('INSERT','UPDATE') AND v_tipo = 'venda' THEN
    IF v_kg_antes - NEW.kg_total <= 0 THEN
      -- Avança 1 microssegundo para começar o novo ciclo depois desta venda
      v_reset_at := (COALESCE(NEW.data, v_data) + interval '1 microsecond');

      INSERT INTO public.estoque_reset AS er (material_id, reset_at)
      VALUES (v_material_id, v_reset_at)
      ON CONFLICT (material_id) DO UPDATE
        SET reset_at = EXCLUDED.reset_at;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_estoque_reset_apos_movimento"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."relatorio_geral_periodo"("data_inicio" "date", "data_fim" "date") RETURNS TABLE("nome" "text", "kg_compra" numeric, "gasto_compra" numeric, "kg_venda" numeric, "receita_venda" numeric, "despesa_total" numeric, "lucro" numeric)
    LANGUAGE "sql"
    AS $$
  WITH
  compras AS (
    SELECT
      m.nome,
      COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4)   AS kg_compra,
      COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS gasto_compra
    FROM public.item i
    JOIN public.comanda c ON c.id = i.comanda
    JOIN public.material m ON m.id = i.material
    WHERE c.tipo = 'compra'::public.comanda_tipo
      AND i.data >= data_inicio::timestamptz
      AND i.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
    GROUP BY m.nome
  ),
  vendas AS (
    SELECT
      m.nome,
      COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4)   AS kg_venda,
      COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS receita_venda
    FROM public.item i
    JOIN public.comanda c ON c.id = i.comanda
    JOIN public.material m ON m.id = i.material
    WHERE c.tipo = 'venda'::public.comanda_tipo
      AND i.data >= data_inicio::timestamptz
      AND i.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
    GROUP BY m.nome
  ),
  desp AS (
    SELECT COALESCE(SUM(d.valor), 0)::NUMERIC(14,4) AS despesa_total
    FROM public.despesa d
    WHERE d.data >= data_inicio::timestamptz
      AND d.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
  )
  SELECT
    COALESCE(n.nome, v.nome)                                           AS nome,
    COALESCE(n.kg_compra,     0)::NUMERIC(14,4)                        AS kg_compra,
    COALESCE(n.gasto_compra,  0)::NUMERIC(14,4)                        AS gasto_compra,
    COALESCE(v.kg_venda,      0)::NUMERIC(14,4)                        AS kg_venda,
    COALESCE(v.receita_venda, 0)::NUMERIC(14,4)                        AS receita_venda,
    (SELECT despesa_total FROM desp)                                    AS despesa_total,
    (
      COALESCE(v.receita_venda, 0)
      - COALESCE(n.gasto_compra, 0)
      - COALESCE((SELECT despesa_total FROM desp), 0)
    )::NUMERIC(14,4)                                                   AS lucro
  FROM compras n
  FULL JOIN vendas v ON v.nome = n.nome
  ORDER BY nome;
$$;


ALTER FUNCTION "public"."relatorio_geral_periodo"("data_inicio" "date", "data_fim" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."relatorio_personalizado"("data_inicio" "date", "data_fim" "date") RETURNS TABLE("data" "date", "compra" numeric, "venda" numeric, "despesa" numeric, "lucro" numeric)
    LANGUAGE "sql"
    AS $$
  WITH compras AS (
    SELECT date_trunc('day', i.data)::date AS dia, SUM(i.valor_total) AS compra
    FROM public.item i
    JOIN public.comanda c ON c.id = i.comanda
    WHERE c.tipo = 'compra'
      AND i.data BETWEEN data_inicio AND data_fim
    GROUP BY 1
  ),
  vendas AS (
    SELECT date_trunc('day', i.data)::date AS dia, SUM(i.valor_total) AS venda
    FROM public.item i
    JOIN public.comanda c ON c.id = i.comanda
    WHERE c.tipo = 'venda'
      AND i.data BETWEEN data_inicio AND data_fim
    GROUP BY 1
  ),
  despesas AS (
    SELECT date_trunc('day', d.data)::date AS dia, SUM(d.valor) AS despesa
    FROM public.despesa d
    WHERE d.data BETWEEN data_inicio AND data_fim
    GROUP BY 1
  )
  SELECT
    d::date AS data,
    COALESCE(c.compra,0)::NUMERIC(14,4) AS compra,
    COALESCE(v.venda,0)::NUMERIC(14,4) AS venda,
    COALESCE(e.despesa,0)::NUMERIC(14,4) AS despesa,
    (COALESCE(v.venda,0) - COALESCE(c.compra,0) - COALESCE(e.despesa,0))::NUMERIC(14,4) AS lucro
  FROM generate_series(data_inicio, data_fim, interval '1 day') AS d
  LEFT JOIN compras c ON c.dia = d
  LEFT JOIN vendas v ON v.dia = d
  LEFT JOIN despesas e ON e.dia = d
  ORDER BY data;
$$;


ALTER FUNCTION "public"."relatorio_personalizado"("data_inicio" "date", "data_fim" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."relatorio_personalizado"("data_inicio" "date", "data_fim" "date") IS 'Função RPC para gerar relatórios personalizados por intervalo de datas (compra, venda, despesa, lucro).';



CREATE OR REPLACE FUNCTION "public"."resumo_periodo"("data_inicio" "date", "data_fim" "date") RETURNS TABLE("total_kg_compra" numeric, "total_gasto_compra" numeric, "total_kg_venda" numeric, "total_receita_venda" numeric, "total_despesa" numeric, "lucro_final" numeric)
    LANGUAGE "sql"
    AS $$
  WITH
  -- Soma geral de compras
  compras AS (
    SELECT
      COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4)   AS total_kg_compra,
      COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS total_gasto_compra
    FROM public.item i
    JOIN public.comanda c ON c.id = i.comanda
    WHERE c.tipo = 'compra'::public.comanda_tipo
      AND i.data >= data_inicio::timestamptz
      AND i.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
  ),

  -- Soma geral de vendas
  vendas AS (
    SELECT
      COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4)   AS total_kg_venda,
      COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS total_receita_venda
    FROM public.item i
    JOIN public.comanda c ON c.id = i.comanda
    WHERE c.tipo = 'venda'::public.comanda_tipo
      AND i.data >= data_inicio::timestamptz
      AND i.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
  ),

  -- Soma geral de despesas
  desp AS (
    SELECT
      COALESCE(SUM(d.valor), 0)::NUMERIC(14,4) AS total_despesa
    FROM public.despesa d
    WHERE d.data >= data_inicio::timestamptz
      AND d.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
  )

  SELECT
    c.total_kg_compra,
    c.total_gasto_compra,
    v.total_kg_venda,
    v.total_receita_venda,
    d.total_despesa,
    (
      COALESCE(v.total_receita_venda, 0)
      - COALESCE(c.total_gasto_compra, 0)
      - COALESCE(d.total_despesa, 0)
    )::NUMERIC(14,4) AS lucro_final
  FROM compras c, vendas v, desp d;
$$;


ALTER FUNCTION "public"."resumo_periodo"("data_inicio" "date", "data_fim" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venda_por_material_periodo"("data_inicio" "date", "data_fim" "date") RETURNS TABLE("nome" "text", "kg" numeric, "gasto" numeric)
    LANGUAGE "sql"
    AS $$
  SELECT
    m.nome AS nome,
    COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4)   AS kg,
    COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS gasto
  FROM public.item i
  JOIN public.comanda c ON c.id = i.comanda
  JOIN public.material m ON m.id = i.material
  WHERE c.tipo = 'venda'::public.comanda_tipo
    AND i.data >= data_inicio::timestamptz
    AND i.data <  (data_fim::date + INTERVAL '1 day')::timestamptz
  GROUP BY m.nome
  ORDER BY m.nome;
$$;


ALTER FUNCTION "public"."venda_por_material_periodo"("data_inicio" "date", "data_fim" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venda_por_material_personalizado"("data_inicio" "date", "data_fim" "date") RETURNS TABLE("nome" "text", "kg" numeric, "total" numeric, "preco_medio" numeric)
    LANGUAGE "sql"
    AS $$
  SELECT
    m.nome AS nome,
    COALESCE(SUM(i.kg_total), 0)::NUMERIC(14,4) AS kg,
    COALESCE(SUM(i.valor_total), 0)::NUMERIC(14,4) AS total,
    CASE 
      WHEN SUM(i.kg_total) > 0 
      THEN (SUM(i.valor_total) / SUM(i.kg_total))::NUMERIC(14,4)
      ELSE 0::NUMERIC(14,4)
    END AS preco_medio
  FROM item i
  JOIN comanda c ON c.id = i.comanda
  JOIN material m ON m.id = i.material
  WHERE c.tipo = 'venda'
    AND i.data BETWEEN data_inicio AND data_fim
  GROUP BY m.nome
  ORDER BY nome;
$$;


ALTER FUNCTION "public"."venda_por_material_personalizado"("data_inicio" "date", "data_fim" "date") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."comanda" (
    "id" bigint NOT NULL,
    "data" timestamp with time zone DEFAULT "now"() NOT NULL,
    "codigo" "text" NOT NULL,
    "tipo" "public"."comanda_tipo" NOT NULL,
    "observacoes" "text",
    "total" numeric(14,4) DEFAULT 0 NOT NULL,
    "criado_por" "text" NOT NULL,
    "atualizado_por" "text" NOT NULL
);


ALTER TABLE "public"."comanda" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."despesa" (
    "id" bigint NOT NULL,
    "data" timestamp with time zone DEFAULT "now"() NOT NULL,
    "descricao" "text" NOT NULL,
    "valor" numeric(14,4) DEFAULT 0 NOT NULL,
    "criado_por" "text" NOT NULL,
    "atualizado_por" "text" NOT NULL
);


ALTER TABLE "public"."despesa" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fechamento" (
    "id" bigint NOT NULL,
    "data" timestamp with time zone DEFAULT "now"() NOT NULL,
    "compra" numeric(14,4) DEFAULT 0 NOT NULL,
    "despesa" numeric(14,4) DEFAULT 0 NOT NULL,
    "venda" numeric(14,4) DEFAULT 0 NOT NULL,
    "lucro" numeric(14,4) DEFAULT 0 NOT NULL,
    "observacao" "text",
    "criado_por" "text" NOT NULL,
    "atualizado_por" "text" NOT NULL
);


ALTER TABLE "public"."fechamento" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."item" (
    "id" bigint NOT NULL,
    "data" timestamp with time zone DEFAULT "now"() NOT NULL,
    "material" bigint NOT NULL,
    "comanda" bigint NOT NULL,
    "preco_kg" numeric(14,4) DEFAULT 0 NOT NULL,
    "kg_total" numeric(14,4) DEFAULT 0 NOT NULL,
    "valor_total" numeric(14,4) DEFAULT 0 NOT NULL,
    "criado_por" "text" NOT NULL,
    "atualizado_por" "text" NOT NULL
);


ALTER TABLE "public"."item" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."calculo_fechamento" AS
 WITH "ultimo" AS (
         SELECT COALESCE("max"("f"."data"), "to_timestamp"((0)::double precision)) AS "dt"
           FROM "public"."fechamento" "f"
        ), "compra" AS (
         SELECT (COALESCE("sum"("i"."valor_total"), (0)::numeric))::numeric(14,4) AS "total_compra"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
          WHERE (("c"."tipo" = 'compra'::"public"."comanda_tipo") AND ("i"."data" > ( SELECT "ultimo"."dt"
                   FROM "ultimo")))
        ), "venda" AS (
         SELECT (COALESCE("sum"("i"."valor_total"), (0)::numeric))::numeric(14,4) AS "total_venda"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
          WHERE (("c"."tipo" = 'venda'::"public"."comanda_tipo") AND ("i"."data" > ( SELECT "ultimo"."dt"
                   FROM "ultimo")))
        ), "gastos" AS (
         SELECT (COALESCE("sum"("d"."valor"), (0)::numeric))::numeric(14,4) AS "total_despesa"
           FROM "public"."despesa" "d"
          WHERE ("d"."data" > ( SELECT "ultimo"."dt"
                   FROM "ultimo"))
        )
 SELECT ( SELECT "ultimo"."dt"
           FROM "ultimo") AS "desde_data",
    "now"() AS "ate_data",
    ( SELECT "compra"."total_compra"
           FROM "compra") AS "compra",
    ( SELECT "gastos"."total_despesa"
           FROM "gastos") AS "despesa",
    ( SELECT "venda"."total_venda"
           FROM "venda") AS "venda",
    (((( SELECT "venda"."total_venda"
           FROM "venda") - ( SELECT "compra"."total_compra"
           FROM "compra")) - ( SELECT "gastos"."total_despesa"
           FROM "gastos")))::numeric(14,4) AS "lucro";


ALTER VIEW "public"."calculo_fechamento" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."comanda_20" AS
 WITH "ultimas" AS (
         SELECT "c_1"."id"
           FROM "public"."comanda" "c_1"
          ORDER BY "c_1"."data" DESC, "c_1"."id" DESC
         LIMIT 20
        )
 SELECT "c"."id" AS "comanda_id",
    "c"."data" AS "comanda_data",
    "c"."codigo",
    "c"."tipo" AS "comanda_tipo",
    "c"."observacoes",
    "c"."total" AS "comanda_total",
    "i"."id" AS "item_id",
    "i"."data" AS "item_data",
    "i"."material" AS "material_id",
    "i"."preco_kg",
    "i"."kg_total",
    "i"."valor_total" AS "item_valor_total"
   FROM (("public"."comanda" "c"
     JOIN "ultimas" "u" ON (("u"."id" = "c"."id")))
     LEFT JOIN "public"."item" "i" ON (("i"."comanda" = "c"."id")))
  ORDER BY "c"."data" DESC, "c"."id" DESC, "i"."id";


ALTER VIEW "public"."comanda_20" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."comanda_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."comanda_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."comanda_id_seq" OWNED BY "public"."comanda"."id";



CREATE TABLE IF NOT EXISTS "public"."material" (
    "id" bigint NOT NULL,
    "data" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nome" "text" NOT NULL,
    "categoria" "text" NOT NULL,
    "preco_compra" numeric(14,4) DEFAULT 0 NOT NULL,
    "preco_venda" numeric(14,4) DEFAULT 0 NOT NULL,
    "criado_por" "text" NOT NULL,
    "atualizado_por" "text" NOT NULL
);


ALTER TABLE "public"."material" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."compra_por_material_anual" AS
 SELECT "m"."nome",
    ("date_trunc"('year'::"text", CURRENT_TIMESTAMP))::"date" AS "referencia",
    ("sum"("i"."kg_total"))::numeric(14,4) AS "kg",
    ("sum"("i"."valor_total"))::numeric(14,4) AS "gasto"
   FROM (("public"."item" "i"
     JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
     JOIN "public"."material" "m" ON (("m"."id" = "i"."material")))
  WHERE (("c"."tipo" = 'compra'::"public"."comanda_tipo") AND ("i"."data" >= "date_trunc"('year'::"text", CURRENT_TIMESTAMP)) AND ("i"."data" < ("date_trunc"('year'::"text", CURRENT_TIMESTAMP) + '1 year'::interval)))
  GROUP BY "m"."nome"
  ORDER BY "m"."nome";


ALTER VIEW "public"."compra_por_material_anual" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."compra_por_material_diario" AS
 SELECT "m"."nome",
    ("date_trunc"('day'::"text", CURRENT_TIMESTAMP))::"date" AS "data",
    ("sum"("i"."kg_total"))::numeric(14,4) AS "kg",
    ("sum"("i"."valor_total"))::numeric(14,4) AS "gasto"
   FROM (("public"."item" "i"
     JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
     JOIN "public"."material" "m" ON (("m"."id" = "i"."material")))
  WHERE (("c"."tipo" = 'compra'::"public"."comanda_tipo") AND ("i"."data" >= "date_trunc"('day'::"text", CURRENT_TIMESTAMP)) AND ("i"."data" < ("date_trunc"('day'::"text", CURRENT_TIMESTAMP) + '1 day'::interval)))
  GROUP BY "m"."nome"
  ORDER BY "m"."nome";


ALTER VIEW "public"."compra_por_material_diario" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."compra_por_material_mes" AS
 SELECT "m"."nome",
    ("date_trunc"('month'::"text", CURRENT_TIMESTAMP))::"date" AS "referencia",
    ("sum"("i"."kg_total"))::numeric(14,4) AS "kg",
    ("sum"("i"."valor_total"))::numeric(14,4) AS "gasto"
   FROM (("public"."item" "i"
     JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
     JOIN "public"."material" "m" ON (("m"."id" = "i"."material")))
  WHERE (("c"."tipo" = 'compra'::"public"."comanda_tipo") AND ("i"."data" >= "date_trunc"('month'::"text", CURRENT_TIMESTAMP)) AND ("i"."data" < ("date_trunc"('month'::"text", CURRENT_TIMESTAMP) + '1 mon'::interval)))
  GROUP BY "m"."nome"
  ORDER BY "m"."nome";


ALTER VIEW "public"."compra_por_material_mes" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."despesa_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."despesa_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."despesa_id_seq" OWNED BY "public"."despesa"."id";



CREATE OR REPLACE VIEW "public"."despesa_mes" AS
 SELECT "id",
    "data",
    "descricao",
    "valor",
    "criado_por",
    "atualizado_por"
   FROM "public"."despesa" "d"
  WHERE ("date_trunc"('month'::"text", "data") = "date_trunc"('month'::"text", "now"()))
  ORDER BY "data" DESC, "id" DESC;


ALTER VIEW "public"."despesa_mes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estoque_reset" (
    "material_id" bigint NOT NULL,
    "reset_at" timestamp with time zone DEFAULT "to_timestamp"((0)::double precision) NOT NULL
);


ALTER TABLE "public"."estoque_reset" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."estoque" AS
 WITH "params" AS (
         SELECT "m"."id" AS "material_id",
            "m"."nome" AS "material",
            COALESCE("er"."reset_at", "to_timestamp"((0)::double precision)) AS "last_reset_ts"
           FROM ("public"."material" "m"
             LEFT JOIN "public"."estoque_reset" "er" ON (("er"."material_id" = "m"."id")))
        ), "compras" AS (
         SELECT "i"."material" AS "material_id",
            "sum"("i"."kg_total") AS "kg_compra",
            "sum"("i"."valor_total") AS "gasto_compra"
           FROM (("public"."item" "i"
             JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
             JOIN "params" "p" ON (("p"."material_id" = "i"."material")))
          WHERE (("c"."tipo" = 'compra'::"public"."comanda_tipo") AND ("i"."data" > "p"."last_reset_ts"))
          GROUP BY "i"."material"
        ), "vendas" AS (
         SELECT "i"."material" AS "material_id",
            "sum"("i"."kg_total") AS "kg_venda"
           FROM (("public"."item" "i"
             JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
             JOIN "params" "p" ON (("p"."material_id" = "i"."material")))
          WHERE (("c"."tipo" = 'venda'::"public"."comanda_tipo") AND ("i"."data" > "p"."last_reset_ts"))
          GROUP BY "i"."material"
        ), "base" AS (
         SELECT "p"."material",
            (COALESCE("c"."kg_compra", (0)::numeric))::numeric(14,4) AS "kg_compra",
            (COALESCE("c"."gasto_compra", (0)::numeric))::numeric(14,4) AS "gasto_compra",
            (COALESCE("v"."kg_venda", (0)::numeric))::numeric(14,4) AS "kg_venda"
           FROM (("params" "p"
             LEFT JOIN "compras" "c" ON (("c"."material_id" = "p"."material_id")))
             LEFT JOIN "vendas" "v" ON (("v"."material_id" = "p"."material_id")))
        )
 SELECT "material",
    (GREATEST(("kg_compra" - "kg_venda"), (0)::numeric))::numeric(14,4) AS "kg_total",
        CASE
            WHEN ("kg_compra" > (0)::numeric) THEN (("gasto_compra" / "kg_compra"))::numeric(14,4)
            ELSE (0)::numeric(14,4)
        END AS "valor_medio_kg",
    (
        CASE
            WHEN ("kg_compra" > (0)::numeric) THEN (("gasto_compra" / "kg_compra") * GREATEST(("kg_compra" - "kg_venda"), (0)::numeric))
            ELSE (0)::numeric
        END)::numeric(14,4) AS "valor_total_gasto"
   FROM "base"
  ORDER BY "material";


ALTER VIEW "public"."estoque" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."fechamento_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."fechamento_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."fechamento_id_seq" OWNED BY "public"."fechamento"."id";



CREATE OR REPLACE VIEW "public"."fechamento_mes" AS
 SELECT "id",
    "data",
    "compra",
    "despesa",
    "venda",
    "lucro",
    "observacao",
    "criado_por",
    "atualizado_por"
   FROM "public"."fechamento" "f"
  WHERE ("date_trunc"('month'::"text", "data") = "date_trunc"('month'::"text", "now"()))
  ORDER BY "data" DESC;


ALTER VIEW "public"."fechamento_mes" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."item_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."item_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."item_id_seq" OWNED BY "public"."item"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."material_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."material_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."material_id_seq" OWNED BY "public"."material"."id";



CREATE TABLE IF NOT EXISTS "public"."pendencia" (
    "id" bigint NOT NULL,
    "data" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" boolean DEFAULT false NOT NULL,
    "nome" "text" NOT NULL,
    "valor" numeric(14,4) DEFAULT 0 NOT NULL,
    "tipo" "public"."pendencia_tipo" NOT NULL,
    "observacao" "text",
    "criado_por" "text" NOT NULL,
    "atualizado_por" "text" NOT NULL
);


ALTER TABLE "public"."pendencia" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."pendencia_false" AS
 SELECT "id",
    "data",
    "status",
    "nome",
    "valor",
    "tipo",
    "observacao",
    "criado_por",
    "atualizado_por"
   FROM "public"."pendencia"
  WHERE ("status" = false);


ALTER VIEW "public"."pendencia_false" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."pendencia_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pendencia_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pendencia_id_seq" OWNED BY "public"."pendencia"."id";



CREATE OR REPLACE VIEW "public"."relatorio_anual" AS
 WITH "compras" AS (
         SELECT "date_trunc"('year'::"text", "i"."data") AS "ano",
            "sum"("i"."valor_total") AS "compra"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c_1" ON (("c_1"."id" = "i"."comanda")))
          WHERE ("c_1"."tipo" = 'compra'::"public"."comanda_tipo")
          GROUP BY ("date_trunc"('year'::"text", "i"."data"))
        ), "vendas" AS (
         SELECT "date_trunc"('year'::"text", "i"."data") AS "ano",
            "sum"("i"."valor_total") AS "venda"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c_1" ON (("c_1"."id" = "i"."comanda")))
          WHERE ("c_1"."tipo" = 'venda'::"public"."comanda_tipo")
          GROUP BY ("date_trunc"('year'::"text", "i"."data"))
        ), "despesas" AS (
         SELECT "date_trunc"('year'::"text", "d"."data") AS "ano",
            "sum"("d"."valor") AS "despesa"
           FROM "public"."despesa" "d"
          GROUP BY ("date_trunc"('year'::"text", "d"."data"))
        )
 SELECT "base"."ano" AS "referencia",
    (COALESCE("c"."compra", (0)::numeric))::numeric(14,4) AS "compra",
    (COALESCE("v"."venda", (0)::numeric))::numeric(14,4) AS "venda",
    (COALESCE("e"."despesa", (0)::numeric))::numeric(14,4) AS "despesa",
    (((COALESCE("v"."venda", (0)::numeric) - COALESCE("c"."compra", (0)::numeric)) - COALESCE("e"."despesa", (0)::numeric)))::numeric(14,4) AS "lucro"
   FROM (((( SELECT DISTINCT ("date_trunc"('year'::"text", "x"."d"))::"date" AS "ano"
           FROM ( SELECT "i"."data" AS "d"
                   FROM "public"."item" "i"
                UNION ALL
                 SELECT "d"."data" AS "d"
                   FROM "public"."despesa" "d") "x") "base"
     LEFT JOIN "compras" "c" ON (("c"."ano" = "base"."ano")))
     LEFT JOIN "vendas" "v" ON (("v"."ano" = "base"."ano")))
     LEFT JOIN "despesas" "e" ON (("e"."ano" = "base"."ano")))
  ORDER BY "base"."ano" DESC;


ALTER VIEW "public"."relatorio_anual" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."relatorio_diario" AS
 WITH "compras" AS (
         SELECT "date_trunc"('day'::"text", "i"."data") AS "dia",
            "sum"("i"."valor_total") AS "compra"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c_1" ON (("c_1"."id" = "i"."comanda")))
          WHERE ("c_1"."tipo" = 'compra'::"public"."comanda_tipo")
          GROUP BY ("date_trunc"('day'::"text", "i"."data"))
        ), "vendas" AS (
         SELECT "date_trunc"('day'::"text", "i"."data") AS "dia",
            "sum"("i"."valor_total") AS "venda"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c_1" ON (("c_1"."id" = "i"."comanda")))
          WHERE ("c_1"."tipo" = 'venda'::"public"."comanda_tipo")
          GROUP BY ("date_trunc"('day'::"text", "i"."data"))
        ), "despesas" AS (
         SELECT "date_trunc"('day'::"text", "d_1"."data") AS "dia",
            "sum"("d_1"."valor") AS "despesa"
           FROM "public"."despesa" "d_1"
          GROUP BY ("date_trunc"('day'::"text", "d_1"."data"))
        )
 SELECT ("d"."d")::"date" AS "data",
    (COALESCE("c"."compra", (0)::numeric))::numeric(14,4) AS "compra",
    (COALESCE("v"."venda", (0)::numeric))::numeric(14,4) AS "venda",
    (COALESCE("e"."despesa", (0)::numeric))::numeric(14,4) AS "despesa",
    (((COALESCE("v"."venda", (0)::numeric) - COALESCE("c"."compra", (0)::numeric)) - COALESCE("e"."despesa", (0)::numeric)))::numeric(14,4) AS "lucro"
   FROM ((("generate_series"(( SELECT "min"("s"."mind") AS "min"
           FROM ( SELECT "min"("i"."data") AS "mind"
                   FROM "public"."item" "i"
                UNION ALL
                 SELECT "min"("d_1"."data") AS "mind"
                   FROM "public"."despesa" "d_1") "s"), "now"(), '1 day'::interval) "d"("d")
     LEFT JOIN "compras" "c" ON (("date_trunc"('day'::"text", "d"."d") = "c"."dia")))
     LEFT JOIN "vendas" "v" ON (("date_trunc"('day'::"text", "d"."d") = "v"."dia")))
     LEFT JOIN "despesas" "e" ON (("date_trunc"('day'::"text", "d"."d") = "e"."dia")))
  ORDER BY (("d"."d")::"date") DESC;


ALTER VIEW "public"."relatorio_diario" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."relatorio_mensal" AS
 WITH "compras" AS (
         SELECT "date_trunc"('month'::"text", "i"."data") AS "mes",
            "sum"("i"."valor_total") AS "compra"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c_1" ON (("c_1"."id" = "i"."comanda")))
          WHERE ("c_1"."tipo" = 'compra'::"public"."comanda_tipo")
          GROUP BY ("date_trunc"('month'::"text", "i"."data"))
        ), "vendas" AS (
         SELECT "date_trunc"('month'::"text", "i"."data") AS "mes",
            "sum"("i"."valor_total") AS "venda"
           FROM ("public"."item" "i"
             JOIN "public"."comanda" "c_1" ON (("c_1"."id" = "i"."comanda")))
          WHERE ("c_1"."tipo" = 'venda'::"public"."comanda_tipo")
          GROUP BY ("date_trunc"('month'::"text", "i"."data"))
        ), "despesas" AS (
         SELECT "date_trunc"('month'::"text", "d"."data") AS "mes",
            "sum"("d"."valor") AS "despesa"
           FROM "public"."despesa" "d"
          GROUP BY ("date_trunc"('month'::"text", "d"."data"))
        )
 SELECT "base"."mes" AS "referencia",
    (COALESCE("c"."compra", (0)::numeric))::numeric(14,4) AS "compra",
    (COALESCE("v"."venda", (0)::numeric))::numeric(14,4) AS "venda",
    (COALESCE("e"."despesa", (0)::numeric))::numeric(14,4) AS "despesa",
    (((COALESCE("v"."venda", (0)::numeric) - COALESCE("c"."compra", (0)::numeric)) - COALESCE("e"."despesa", (0)::numeric)))::numeric(14,4) AS "lucro"
   FROM (((( SELECT DISTINCT ("date_trunc"('month'::"text", "x"."d"))::"date" AS "mes"
           FROM ( SELECT "i"."data" AS "d"
                   FROM "public"."item" "i"
                UNION ALL
                 SELECT "d"."data" AS "d"
                   FROM "public"."despesa" "d") "x") "base"
     LEFT JOIN "compras" "c" ON (("c"."mes" = "base"."mes")))
     LEFT JOIN "vendas" "v" ON (("v"."mes" = "base"."mes")))
     LEFT JOIN "despesas" "e" ON (("e"."mes" = "base"."mes")))
  ORDER BY "base"."mes" DESC;


ALTER VIEW "public"."relatorio_mensal" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."resumo_estoque_financeiro" AS
 SELECT (COALESCE("sum"("e"."kg_total"), (0)::numeric))::numeric(14,4) AS "total_kg",
    (COALESCE("sum"("e"."valor_total_gasto"), (0)::numeric))::numeric(14,4) AS "total_custo",
    (COALESCE("sum"(("e"."kg_total" * "m"."preco_venda")), (0)::numeric))::numeric(14,4) AS "total_venda_potencial",
    ((COALESCE("sum"(("e"."kg_total" * "m"."preco_venda")), (0)::numeric) - COALESCE("sum"("e"."valor_total_gasto"), (0)::numeric)))::numeric(14,4) AS "lucro_potencial"
   FROM ("public"."estoque" "e"
     JOIN "public"."material" "m" ON (("m"."nome" = "e"."material")));


ALTER VIEW "public"."resumo_estoque_financeiro" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."ultimas_20" AS
 SELECT "id",
    "data",
    "material",
    "comanda",
    "preco_kg",
    "kg_total",
    "valor_total",
    "criado_por",
    "atualizado_por"
   FROM "public"."item"
  ORDER BY "data" DESC, "id" DESC
 LIMIT 20;


ALTER VIEW "public"."ultimas_20" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vale" (
    "id" bigint NOT NULL,
    "data" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" boolean DEFAULT false NOT NULL,
    "nome" "text" NOT NULL,
    "valor" numeric(14,4) DEFAULT 0 NOT NULL,
    "observacao" "text",
    "criado_por" "text" NOT NULL,
    "atualizado_por" "text" NOT NULL
);


ALTER TABLE "public"."vale" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vale_false" AS
 SELECT "id",
    "data",
    "status",
    "nome",
    "valor",
    "observacao",
    "criado_por",
    "atualizado_por"
   FROM "public"."vale"
  WHERE ("status" = false);


ALTER VIEW "public"."vale_false" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."vale_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."vale_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."vale_id_seq" OWNED BY "public"."vale"."id";



CREATE OR REPLACE VIEW "public"."venda_por_material_anual" AS
 SELECT "m"."nome",
    ("date_trunc"('year'::"text", CURRENT_TIMESTAMP))::"date" AS "referencia",
    ("sum"("i"."kg_total"))::numeric(14,4) AS "kg",
    ("sum"("i"."valor_total"))::numeric(14,4) AS "gasto"
   FROM (("public"."item" "i"
     JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
     JOIN "public"."material" "m" ON (("m"."id" = "i"."material")))
  WHERE (("c"."tipo" = 'venda'::"public"."comanda_tipo") AND ("i"."data" >= "date_trunc"('year'::"text", CURRENT_TIMESTAMP)) AND ("i"."data" < ("date_trunc"('year'::"text", CURRENT_TIMESTAMP) + '1 year'::interval)))
  GROUP BY "m"."nome"
  ORDER BY "m"."nome";


ALTER VIEW "public"."venda_por_material_anual" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."venda_por_material_diario" AS
 SELECT "m"."nome",
    ("date_trunc"('day'::"text", CURRENT_TIMESTAMP))::"date" AS "data",
    ("sum"("i"."kg_total"))::numeric(14,4) AS "kg",
    ("sum"("i"."valor_total"))::numeric(14,4) AS "gasto"
   FROM (("public"."item" "i"
     JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
     JOIN "public"."material" "m" ON (("m"."id" = "i"."material")))
  WHERE (("c"."tipo" = 'venda'::"public"."comanda_tipo") AND ("i"."data" >= "date_trunc"('day'::"text", CURRENT_TIMESTAMP)) AND ("i"."data" < ("date_trunc"('day'::"text", CURRENT_TIMESTAMP) + '1 day'::interval)))
  GROUP BY "m"."nome"
  ORDER BY "m"."nome";


ALTER VIEW "public"."venda_por_material_diario" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."venda_por_material_mes" AS
 SELECT "m"."nome",
    ("date_trunc"('month'::"text", CURRENT_TIMESTAMP))::"date" AS "referencia",
    ("sum"("i"."kg_total"))::numeric(14,4) AS "kg",
    ("sum"("i"."valor_total"))::numeric(14,4) AS "gasto"
   FROM (("public"."item" "i"
     JOIN "public"."comanda" "c" ON (("c"."id" = "i"."comanda")))
     JOIN "public"."material" "m" ON (("m"."id" = "i"."material")))
  WHERE (("c"."tipo" = 'venda'::"public"."comanda_tipo") AND ("i"."data" >= "date_trunc"('month'::"text", CURRENT_TIMESTAMP)) AND ("i"."data" < ("date_trunc"('month'::"text", CURRENT_TIMESTAMP) + '1 mon'::interval)))
  GROUP BY "m"."nome"
  ORDER BY "m"."nome";


ALTER VIEW "public"."venda_por_material_mes" OWNER TO "postgres";


ALTER TABLE ONLY "public"."comanda" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."comanda_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."despesa" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."despesa_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."fechamento" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."fechamento_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."item" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."item_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."material" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."material_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pendencia" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pendencia_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."vale" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."vale_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."comanda"
    ADD CONSTRAINT "comanda_codigo_key" UNIQUE ("codigo");



ALTER TABLE ONLY "public"."comanda"
    ADD CONSTRAINT "comanda_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."despesa"
    ADD CONSTRAINT "despesa_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."estoque_reset"
    ADD CONSTRAINT "estoque_reset_pkey" PRIMARY KEY ("material_id");



ALTER TABLE ONLY "public"."fechamento"
    ADD CONSTRAINT "fechamento_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."item"
    ADD CONSTRAINT "item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material"
    ADD CONSTRAINT "material_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pendencia"
    ADD CONSTRAINT "pendencia_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vale"
    ADD CONSTRAINT "vale_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_comanda_data" ON "public"."comanda" USING "btree" ("data" DESC);



CREATE INDEX "idx_comanda_id_tipo_data" ON "public"."comanda" USING "btree" ("id", "tipo", "data");



CREATE INDEX "idx_comanda_tipo" ON "public"."comanda" USING "btree" ("tipo");



CREATE INDEX "idx_comanda_tipo_data" ON "public"."comanda" USING "btree" ("tipo", "data");



CREATE INDEX "idx_despesa_data" ON "public"."despesa" USING "btree" ("data" DESC);



CREATE INDEX "idx_fechamento_data" ON "public"."fechamento" USING "btree" ("data" DESC);



CREATE INDEX "idx_item_comanda" ON "public"."item" USING "btree" ("comanda");



CREATE INDEX "idx_item_data" ON "public"."item" USING "btree" ("data" DESC);



CREATE INDEX "idx_item_material" ON "public"."item" USING "btree" ("material");



CREATE INDEX "idx_item_material_data" ON "public"."item" USING "btree" ("material", "data");



CREATE INDEX "idx_material_data" ON "public"."material" USING "btree" ("data" DESC);



CREATE INDEX "idx_material_nome" ON "public"."material" USING "btree" ("nome");



CREATE INDEX "idx_pendencia_status" ON "public"."pendencia" USING "btree" ("status");



CREATE INDEX "idx_pendencia_tipo" ON "public"."pendencia" USING "btree" ("tipo");



CREATE INDEX "idx_vale_status" ON "public"."vale" USING "btree" ("status");



CREATE OR REPLACE TRIGGER "trg_estoque_reset_item_insupd" AFTER INSERT OR UPDATE OF "material", "comanda", "kg_total", "data" ON "public"."item" FOR EACH ROW EXECUTE FUNCTION "public"."fn_estoque_reset_apos_movimento"();



ALTER TABLE ONLY "public"."estoque_reset"
    ADD CONSTRAINT "estoque_reset_material_id_fkey" FOREIGN KEY ("material_id") REFERENCES "public"."material"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item"
    ADD CONSTRAINT "item_comanda_fkey" FOREIGN KEY ("comanda") REFERENCES "public"."comanda"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item"
    ADD CONSTRAINT "item_material_fkey" FOREIGN KEY ("material") REFERENCES "public"."material"("id") ON DELETE RESTRICT;





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."comanda";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."despesa";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."fechamento";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."item";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."material";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."pendencia";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."vale";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."compra_por_material_periodo"("data_inicio" "date", "data_fim" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."compra_por_material_periodo"("data_inicio" "date", "data_fim" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."compra_por_material_periodo"("data_inicio" "date", "data_fim" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."compra_por_material_personalizado"("data_inicio" "date", "data_fim" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."compra_por_material_personalizado"("data_inicio" "date", "data_fim" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."compra_por_material_personalizado"("data_inicio" "date", "data_fim" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_estoque_reset_apos_movimento"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_estoque_reset_apos_movimento"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_estoque_reset_apos_movimento"() TO "service_role";



GRANT ALL ON FUNCTION "public"."relatorio_geral_periodo"("data_inicio" "date", "data_fim" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."relatorio_geral_periodo"("data_inicio" "date", "data_fim" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."relatorio_geral_periodo"("data_inicio" "date", "data_fim" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."relatorio_personalizado"("data_inicio" "date", "data_fim" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."relatorio_personalizado"("data_inicio" "date", "data_fim" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."relatorio_personalizado"("data_inicio" "date", "data_fim" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."resumo_periodo"("data_inicio" "date", "data_fim" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."resumo_periodo"("data_inicio" "date", "data_fim" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resumo_periodo"("data_inicio" "date", "data_fim" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."venda_por_material_periodo"("data_inicio" "date", "data_fim" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."venda_por_material_periodo"("data_inicio" "date", "data_fim" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."venda_por_material_periodo"("data_inicio" "date", "data_fim" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."venda_por_material_personalizado"("data_inicio" "date", "data_fim" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."venda_por_material_personalizado"("data_inicio" "date", "data_fim" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."venda_por_material_personalizado"("data_inicio" "date", "data_fim" "date") TO "service_role";


















GRANT ALL ON TABLE "public"."comanda" TO "anon";
GRANT ALL ON TABLE "public"."comanda" TO "authenticated";
GRANT ALL ON TABLE "public"."comanda" TO "service_role";



GRANT ALL ON TABLE "public"."despesa" TO "anon";
GRANT ALL ON TABLE "public"."despesa" TO "authenticated";
GRANT ALL ON TABLE "public"."despesa" TO "service_role";



GRANT ALL ON TABLE "public"."fechamento" TO "anon";
GRANT ALL ON TABLE "public"."fechamento" TO "authenticated";
GRANT ALL ON TABLE "public"."fechamento" TO "service_role";



GRANT ALL ON TABLE "public"."item" TO "anon";
GRANT ALL ON TABLE "public"."item" TO "authenticated";
GRANT ALL ON TABLE "public"."item" TO "service_role";



GRANT ALL ON TABLE "public"."calculo_fechamento" TO "anon";
GRANT ALL ON TABLE "public"."calculo_fechamento" TO "authenticated";
GRANT ALL ON TABLE "public"."calculo_fechamento" TO "service_role";



GRANT ALL ON TABLE "public"."comanda_20" TO "anon";
GRANT ALL ON TABLE "public"."comanda_20" TO "authenticated";
GRANT ALL ON TABLE "public"."comanda_20" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comanda_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comanda_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comanda_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."material" TO "anon";
GRANT ALL ON TABLE "public"."material" TO "authenticated";
GRANT ALL ON TABLE "public"."material" TO "service_role";



GRANT ALL ON TABLE "public"."compra_por_material_anual" TO "anon";
GRANT ALL ON TABLE "public"."compra_por_material_anual" TO "authenticated";
GRANT ALL ON TABLE "public"."compra_por_material_anual" TO "service_role";



GRANT ALL ON TABLE "public"."compra_por_material_diario" TO "anon";
GRANT ALL ON TABLE "public"."compra_por_material_diario" TO "authenticated";
GRANT ALL ON TABLE "public"."compra_por_material_diario" TO "service_role";



GRANT ALL ON TABLE "public"."compra_por_material_mes" TO "anon";
GRANT ALL ON TABLE "public"."compra_por_material_mes" TO "authenticated";
GRANT ALL ON TABLE "public"."compra_por_material_mes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."despesa_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."despesa_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."despesa_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."despesa_mes" TO "anon";
GRANT ALL ON TABLE "public"."despesa_mes" TO "authenticated";
GRANT ALL ON TABLE "public"."despesa_mes" TO "service_role";



GRANT ALL ON TABLE "public"."estoque_reset" TO "anon";
GRANT ALL ON TABLE "public"."estoque_reset" TO "authenticated";
GRANT ALL ON TABLE "public"."estoque_reset" TO "service_role";



GRANT ALL ON TABLE "public"."estoque" TO "anon";
GRANT ALL ON TABLE "public"."estoque" TO "authenticated";
GRANT ALL ON TABLE "public"."estoque" TO "service_role";



GRANT ALL ON SEQUENCE "public"."fechamento_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."fechamento_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."fechamento_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."fechamento_mes" TO "anon";
GRANT ALL ON TABLE "public"."fechamento_mes" TO "authenticated";
GRANT ALL ON TABLE "public"."fechamento_mes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."item_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."item_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."item_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."material_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."material_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."material_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pendencia" TO "anon";
GRANT ALL ON TABLE "public"."pendencia" TO "authenticated";
GRANT ALL ON TABLE "public"."pendencia" TO "service_role";



GRANT ALL ON TABLE "public"."pendencia_false" TO "anon";
GRANT ALL ON TABLE "public"."pendencia_false" TO "authenticated";
GRANT ALL ON TABLE "public"."pendencia_false" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pendencia_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pendencia_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pendencia_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."relatorio_anual" TO "anon";
GRANT ALL ON TABLE "public"."relatorio_anual" TO "authenticated";
GRANT ALL ON TABLE "public"."relatorio_anual" TO "service_role";



GRANT ALL ON TABLE "public"."relatorio_diario" TO "anon";
GRANT ALL ON TABLE "public"."relatorio_diario" TO "authenticated";
GRANT ALL ON TABLE "public"."relatorio_diario" TO "service_role";



GRANT ALL ON TABLE "public"."relatorio_mensal" TO "anon";
GRANT ALL ON TABLE "public"."relatorio_mensal" TO "authenticated";
GRANT ALL ON TABLE "public"."relatorio_mensal" TO "service_role";



GRANT ALL ON TABLE "public"."resumo_estoque_financeiro" TO "anon";
GRANT ALL ON TABLE "public"."resumo_estoque_financeiro" TO "authenticated";
GRANT ALL ON TABLE "public"."resumo_estoque_financeiro" TO "service_role";



GRANT ALL ON TABLE "public"."ultimas_20" TO "anon";
GRANT ALL ON TABLE "public"."ultimas_20" TO "authenticated";
GRANT ALL ON TABLE "public"."ultimas_20" TO "service_role";



GRANT ALL ON TABLE "public"."vale" TO "anon";
GRANT ALL ON TABLE "public"."vale" TO "authenticated";
GRANT ALL ON TABLE "public"."vale" TO "service_role";



GRANT ALL ON TABLE "public"."vale_false" TO "anon";
GRANT ALL ON TABLE "public"."vale_false" TO "authenticated";
GRANT ALL ON TABLE "public"."vale_false" TO "service_role";



GRANT ALL ON SEQUENCE "public"."vale_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."vale_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."vale_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."venda_por_material_anual" TO "anon";
GRANT ALL ON TABLE "public"."venda_por_material_anual" TO "authenticated";
GRANT ALL ON TABLE "public"."venda_por_material_anual" TO "service_role";



GRANT ALL ON TABLE "public"."venda_por_material_diario" TO "anon";
GRANT ALL ON TABLE "public"."venda_por_material_diario" TO "authenticated";
GRANT ALL ON TABLE "public"."venda_por_material_diario" TO "service_role";



GRANT ALL ON TABLE "public"."venda_por_material_mes" TO "anon";
GRANT ALL ON TABLE "public"."venda_por_material_mes" TO "authenticated";
GRANT ALL ON TABLE "public"."venda_por_material_mes" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































RESET ALL;

