-- Ativando extensão para criptografia
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Etapa 2: Inserindo trigger function de auditoria
CREATE OR REPLACE FUNCTION audit.log_modificacoes_usuarios()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit.log_usuarios(usuario_id, operacao, dados_novos)
        VALUES (NEW.id, 'INSERT', to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit.log_usuarios(usuario_id, operacao, dados_anteriores, dados_novos)
        VALUES (OLD.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit.log_usuarios(usuario_id, operacao, dados_anteriores)
        VALUES (OLD.id, 'DELETE', to_jsonb(OLD));
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Etapa 3: Aplicando trigger na tabela
CREATE TRIGGER trg_audit_usuarios
AFTER INSERT OR UPDATE OR DELETE ON public.usuarios
FOR EACH ROW EXECUTE FUNCTION audit.log_modificacoes_usuarios();