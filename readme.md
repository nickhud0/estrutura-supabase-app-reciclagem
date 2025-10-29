## PREPARAR E EXPORTAR ESTRUTURA (PROJETO DE ORIGEM)

**Objetivo:** Gerar o arquivo SQL de migração com a estrutura.

Certifique-se de estar no diretório raiz do seu projeto local (`~/supabaseinit`) e que o **Docker esteja rodando**.

Bash usei esse comando para clonar a estrutura 'supabase db dump \
  --db-url 'postgresql://postgres:1zb50by0e1Jb1mrc@db.yckrunqvwtgnkexmlacq.supabase.co:5432/postgres' \
  -f supabase/migrations/schema_manual_$(date +%Y%m%d%H%M%S).sql'

```
# 1. Desloga para garantir um novo token de acesso
supabase logout

# 2. Faz login na conta que possui o PROJETO DE ORIGEM
supabase login

# 3. Vincula ao Projeto de Origem para acesso
supabase link --project-ref <REF_DO_PROJETO_DE_ORIGEM>

# 4. EXPORTA o esquema do banco de dados para um arquivo SQL local
# (O Docker deve estar rodando para este comando)
supabase db pull
```

**Resultado:** Um novo arquivo SQL (ex: `[timestamp]_remote_schema.sql`) é criado em `supabase/migrations`.

---

## 2. IMPORTAR ESTRUTURA (PROJETO DE DESTINO)

**Objetivo:** Aplicar o arquivo SQL gerado no novo projeto Supabase.

### Opção A: Usando `supabase link` (Padrão, se a conta for a mesma)

Bash

```
# 1. Desvincula o projeto de origem
supabase unlink

# 2. Faz login na conta que possui o PROJETO DE DESTINO (se for diferente)
# (Se for a mesma conta, pule esta etapa)
supabase logout
supabase login

# 3. Vincula ao Projeto de Destino
# (A CLI pode pedir a senha do Database do novo projeto)
supabase link --project-ref <REF_DO_PROJETO_DE_DESTINO>
ou
supabase link --project-ref <REF_DO_PROJETO_DE_DESTINO> --debug

# 4. ENVIA o esquema para o novo projeto
supabase db push
```

supabase link --project-ref yckrunqvwtgnkexmlacq
