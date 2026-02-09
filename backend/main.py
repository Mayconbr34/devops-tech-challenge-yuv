"""
Jimi IoT Gateway - Backend API
Recebe webhooks da plataforma Jimi Cloud
"""
import os
import time
import logging
from datetime import datetime
from typing import Optional, Dict, Any, List
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

import structlog

# ===========================================
# Configuração de Logging Estruturado
# ===========================================
def configure_logging():
    """Configura logging estruturado em JSON"""
    structlog.configure(
        processors=[
            structlog.stdlib.filter_by_level,
            structlog.stdlib.add_logger_name,
            structlog.stdlib.add_log_level,
            structlog.stdlib.PositionalArgumentsFormatter(),
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.UnicodeDecoder(),
            structlog.processors.JSONRenderer()
        ],
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )
    
    logging.basicConfig(
        format="%(message)s",
        level=getattr(logging, os.getenv("LOG_LEVEL", "INFO")),
    )

configure_logging()
logger = structlog.get_logger(__name__)

# Token de validação da origem (obrigatório para webhooks)
WEBHOOK_TOKEN = os.getenv("WEBHOOK_TOKEN", "").strip()
if not WEBHOOK_TOKEN:
    logger.warning("webhook_token_missing", detail="Defina WEBHOOK_TOKEN no ambiente")

# ===========================================
# Métricas Prometheus
# ===========================================
# Contadores
WEBHOOKS_RECEIVED = Counter(
    'jimi_webhooks_received_total',
    'Total de webhooks recebidos',
    ['endpoint', 'status']
)

HTTP_REQUESTS_TOTAL = Counter(
    'jimi_http_requests_total',
    'Total de requisições HTTP',
    ['method', 'endpoint', 'status']
)

HTTP_ERRORS_TOTAL = Counter(
    'jimi_http_errors_total',
    'Total de erros HTTP',
    ['endpoint', 'status']
)

# Histogramas
REQUEST_LATENCY = Histogram(
    'jimi_request_latency_ms',
    'Latência das requisições em milissegundos',
    ['endpoint'],
    buckets=[5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
)

PAYLOAD_SIZE = Histogram(
    'jimi_payload_size_bytes',
    'Tamanho do payload em bytes',
    ['endpoint'],
    buckets=[100, 500, 1000, 5000, 10000, 50000, 100000]
)

# Gauges
ACTIVE_CONNECTIONS = Gauge(
    'jimi_active_connections',
    'Conexões ativas no momento'
)

LAST_WEBHOOK_TIMESTAMP = Gauge(
    'jimi_last_webhook_timestamp',
    'Timestamp do último webhook recebido',
    ['endpoint']
)

# ===========================================
# Modelos Pydantic (Schemas)
# ===========================================
class TelemetryPayload(BaseModel):
    """Schema para dados de telemetria"""
    device_id: str = Field(..., min_length=1, max_length=64, description="ID do dispositivo")
    timestamp: datetime = Field(..., description="Timestamp do evento")
    latitude: Optional[float] = Field(None, ge=-90, le=90)
    longitude: Optional[float] = Field(None, ge=-180, le=180)
    speed: Optional[float] = Field(None, ge=0, description="Velocidade em km/h")
    altitude: Optional[float] = Field(None, description="Altitude em metros")
    heading: Optional[float] = Field(None, ge=0, le=360, description="Direção em graus")
    satellites: Optional[int] = Field(None, ge=0, description="Número de satélites")
    battery: Optional[float] = Field(None, ge=0, le=100, description="Nível de bateria")
    ignition: Optional[bool] = Field(None, description="Estado da ignição")
    data: Optional[Dict[str, Any]] = Field(default_factory=dict, description="Dados adicionais")

    class Config:
        json_schema_extra = {
            "example": {
                "device_id": "JIMI-001",
                "timestamp": "2025-02-06T12:00:00Z",
                "latitude": -23.5505,
                "longitude": -46.6333,
                "speed": 60.5,
                "battery": 85.0,
                "ignition": True
            }
        }

class AlarmPayload(BaseModel):
    """Schema para alertas e alarmes"""
    device_id: str = Field(..., min_length=1, max_length=64)
    alarm_type: str = Field(..., min_length=1, max_length=64)
    severity: str = Field(..., pattern="^(low|medium|high|critical)$")
    timestamp: datetime
    message: Optional[str] = Field(None, max_length=500)
    latitude: Optional[float] = Field(None, ge=-90, le=90)
    longitude: Optional[float] = Field(None, ge=-180, le=180)
    data: Optional[Dict[str, Any]] = Field(default_factory=dict)

    class Config:
        json_schema_extra = {
            "example": {
                "device_id": "JIMI-001",
                "alarm_type": "overspeed",
                "severity": "high",
                "timestamp": "2025-02-06T12:00:00Z",
                "message": "Velocidade excedeu 120 km/h"
            }
        }

class HeartbeatPayload(BaseModel):
    """Schema para sinais de vida"""
    device_id: str = Field(..., min_length=1, max_length=64)
    timestamp: datetime
    status: str = Field(..., pattern="^(online|offline|idle)$")
    battery: Optional[float] = Field(None, ge=0, le=100)
    signal_strength: Optional[int] = Field(None, ge=0, le=100)
    firmware_version: Optional[str] = Field(None, max_length=32)

    class Config:
        json_schema_extra = {
            "example": {
                "device_id": "JIMI-001",
                "timestamp": "2025-02-06T12:00:00Z",
                "status": "online",
                "battery": 90.0,
                "signal_strength": 75
            }
        }

class SuccessResponse(BaseModel):
    """Resposta de sucesso padrão"""
    status: str = "ok"

class ErrorResponse(BaseModel):
    """Resposta de erro padrão"""
    error: str
    detail: Optional[str] = None
    status: int
    timestamp: datetime = Field(default_factory=datetime.utcnow)

# ===========================================
# Lifecycle e App
# ===========================================
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Gerencia o ciclo de vida da aplicação"""
    logger.info("application_starting", version="1.0.0")
    yield
    logger.info("application_shutting_down")

app = FastAPI(
    title="Jimi IoT Gateway",
    description="API de recepção de webhooks para integração com Jimi Cloud",
    version="1.0.0",
    docs_url="/docs" if os.getenv("APP_ENV") != "production" else None,
    redoc_url="/redoc" if os.getenv("APP_ENV") != "production" else None,
    lifespan=lifespan
)

# ===========================================
# Middlewares
# ===========================================
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    """Middleware para capturar métricas de todas as requisições"""
    ACTIVE_CONNECTIONS.inc()
    start_time = time.time()
    endpoint = request.url.path
    
    try:
        response = None

        # Validação da origem para webhooks (token obrigatório)
        if request.method == "POST" and endpoint.startswith("/v1/"):
            if not WEBHOOK_TOKEN:
                logger.error("webhook_token_not_configured", path=endpoint)
                response = JSONResponse(
                    status_code=500,
                    content=ErrorResponse(
                        error="Server Misconfigured",
                        detail="WEBHOOK_TOKEN is not configured",
                        status=500
                    ).model_dump(mode='json')
                )
            else:
                token = request.headers.get("X-Jimi-Token")
                if token != WEBHOOK_TOKEN:
                    HTTP_ERRORS_TOTAL.labels(endpoint=endpoint, status=401).inc()
                    logger.warning(
                        "webhook_auth_failed",
                        path=endpoint,
                        client_ip=request.client.host if request.client else "unknown"
                    )
                    response = JSONResponse(
                        status_code=401,
                        content=ErrorResponse(
                            error="Unauthorized",
                            detail="Invalid or missing X-Jimi-Token",
                            status=401
                        ).model_dump(mode='json')
                    )

        if response is None:
            response = await call_next(request)
        
        # Calcular latência
        latency_ms = (time.time() - start_time) * 1000
        
        # Registrar métricas
        HTTP_REQUESTS_TOTAL.labels(
            method=request.method,
            endpoint=endpoint,
            status=response.status_code
        ).inc()
        
        REQUEST_LATENCY.labels(endpoint=endpoint).observe(latency_ms)
        
        # Log estruturado
        logger.info(
            "http_request",
            method=request.method,
            path=endpoint,
            status=response.status_code,
            latency_ms=round(latency_ms, 2),
            client_ip=request.client.host if request.client else "unknown"
        )
        
        return response
    except Exception as e:
        HTTP_ERRORS_TOTAL.labels(
            endpoint=request.url.path,
            status=500
        ).inc()
        logger.error("request_error", error=str(e), path=request.url.path)
        raise
    finally:
        ACTIVE_CONNECTIONS.dec()

# ===========================================
# Endpoints
# ===========================================
@app.get("/health", tags=["Health"])
async def health_check():
    """
    Health check endpoint para verificação de disponibilidade.
    Usado pelo proxy reverso e orchestrator.
    """
    return {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}

@app.get("/ready", tags=["Health"])
async def readiness_check():
    """
    Readiness check - verifica se a aplicação está pronta para receber tráfego
    """
    return {"status": "ready", "timestamp": datetime.utcnow().isoformat()}

@app.get("/metrics", tags=["Observability"])
async def metrics():
    """
    Endpoint de métricas no formato Prometheus.
    Expõe todas as métricas coletadas pela aplicação.
    """
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST
    )

@app.post("/v1/telemetry", response_model=SuccessResponse, tags=["Webhooks"])
async def receive_telemetry(payload: TelemetryPayload, request: Request):
    """
    Recebe dados de telemetria dos dispositivos IoT.
    
    - **device_id**: Identificador único do dispositivo
    - **timestamp**: Momento da coleta dos dados
    - **latitude/longitude**: Coordenadas GPS
    - **speed**: Velocidade em km/h
    - **battery**: Nível de bateria (0-100%)
    """
    endpoint = "telemetry"
    
    try:
        # Registrar tamanho do payload
        content_length = request.headers.get("content-length", 0)
        PAYLOAD_SIZE.labels(endpoint=endpoint).observe(int(content_length))
        
        # Incrementar contador de webhooks
        WEBHOOKS_RECEIVED.labels(endpoint=endpoint, status="success").inc()
        LAST_WEBHOOK_TIMESTAMP.labels(endpoint=endpoint).set_to_current_time()
        
        # Log do evento
        logger.info(
            "telemetry_received",
            device_id=payload.device_id,
            timestamp=payload.timestamp.isoformat(),
            has_gps=payload.latitude is not None and payload.longitude is not None
        )
        
        return SuccessResponse()
        
    except Exception as e:
        WEBHOOKS_RECEIVED.labels(endpoint=endpoint, status="error").inc()
        HTTP_ERRORS_TOTAL.labels(endpoint=endpoint, status=500).inc()
        logger.error("telemetry_error", error=str(e), device_id=payload.device_id)
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/v1/alarms", response_model=SuccessResponse, tags=["Webhooks"])
async def receive_alarm(payload: AlarmPayload, request: Request):
    """
    Recebe alertas e alarmes dos dispositivos.
    
    - **device_id**: Identificador do dispositivo
    - **alarm_type**: Tipo do alarme (ex: overspeed, geofence, sos)
    - **severity**: Severidade (low, medium, high, critical)
    """
    endpoint = "alarms"
    
    try:
        content_length = request.headers.get("content-length", 0)
        PAYLOAD_SIZE.labels(endpoint=endpoint).observe(int(content_length))
        
        WEBHOOKS_RECEIVED.labels(endpoint=endpoint, status="success").inc()
        LAST_WEBHOOK_TIMESTAMP.labels(endpoint=endpoint).set_to_current_time()
        
        logger.warning(
            "alarm_received",
            device_id=payload.device_id,
            alarm_type=payload.alarm_type,
            severity=payload.severity,
            message=payload.message
        )
        
        return SuccessResponse()
        
    except Exception as e:
        WEBHOOKS_RECEIVED.labels(endpoint=endpoint, status="error").inc()
        HTTP_ERRORS_TOTAL.labels(endpoint=endpoint, status=500).inc()
        logger.error("alarm_error", error=str(e), device_id=payload.device_id)
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/v1/heartbeat", response_model=SuccessResponse, tags=["Webhooks"])
async def receive_heartbeat(payload: HeartbeatPayload, request: Request):
    """
    Recebe sinais de vida (heartbeat) dos dispositivos.
    
    - **device_id**: Identificador do dispositivo
    - **status**: Estado atual (online, offline, idle)
    - **battery**: Nível de bateria
    """
    endpoint = "heartbeat"
    
    try:
        content_length = request.headers.get("content-length", 0)
        PAYLOAD_SIZE.labels(endpoint=endpoint).observe(int(content_length))
        
        WEBHOOKS_RECEIVED.labels(endpoint=endpoint, status="success").inc()
        LAST_WEBHOOK_TIMESTAMP.labels(endpoint=endpoint).set_to_current_time()
        
        logger.info(
            "heartbeat_received",
            device_id=payload.device_id,
            status=payload.status,
            battery=payload.battery
        )
        
        return SuccessResponse()
        
    except Exception as e:
        WEBHOOKS_RECEIVED.labels(endpoint=endpoint, status="error").inc()
        HTTP_ERRORS_TOTAL.labels(endpoint=endpoint, status=500).inc()
        logger.error("heartbeat_error", error=str(e), device_id=payload.device_id)
        raise HTTPException(status_code=500, detail="Internal server error")

# ===========================================
# Exception Handlers
# ===========================================
@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """Handler customizado para exceções HTTP"""
    HTTP_ERRORS_TOTAL.labels(
        endpoint=request.url.path,
        status=exc.status_code
    ).inc()
    
    logger.warning(
        "http_exception",
        path=request.url.path,
        status=exc.status_code,
        detail=exc.detail
    )
    
    return JSONResponse(
        status_code=exc.status_code,
        content=ErrorResponse(
            error=exc.detail or "Error",
            status=exc.status_code
        ).model_dump(mode='json')
    )

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """Handler para payload inválido (retorna 400 conforme requisito)"""
    HTTP_ERRORS_TOTAL.labels(
        endpoint=request.url.path,
        status=400
    ).inc()

    logger.warning(
        "validation_error",
        path=request.url.path,
        errors=exc.errors()
    )

    return JSONResponse(
        status_code=400,
        content=ErrorResponse(
            error="Invalid payload",
            detail="Payload validation failed",
            status=400
        ).model_dump(mode='json')
    )

@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    """Handler para exceções não tratadas"""
    HTTP_ERRORS_TOTAL.labels(
        endpoint=request.url.path,
        status=500
    ).inc()
    
    logger.error(
        "unhandled_exception",
        path=request.url.path,
        error=str(exc),
        error_type=type(exc).__name__
    )
    
    return JSONResponse(
        status_code=500,
        content=ErrorResponse(
            error="Internal Server Error",
            detail="An unexpected error occurred",
            status=500
        ).model_dump(mode='json')
    )

# ===========================================
# Startup
# ===========================================
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
