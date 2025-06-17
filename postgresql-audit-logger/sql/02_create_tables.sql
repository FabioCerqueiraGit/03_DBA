-- Tabela principal simulando um sistema (ex: usuários)
CREATE TABLE public.usuarios (
    id SERIAL PRIMARY KEY,
    nome TEXT NOT NULL,
    email TEXT NOT NULL,
    cpf TEXT NOT NULL,
    criado_em TIMESTAMP DEFAULT NOW()
);

-- Tabela de auditoria
CREATE TABLE audit.log_usuarios (
    id SERIAL PRIMARY KEY,
    usuario_id INTEGER,
    operacao TEXT,
    data_operacao TIMESTAMP DEFAULT NOW(),
    dados_anteriores JSONB,
    dados_novos JSONB
);