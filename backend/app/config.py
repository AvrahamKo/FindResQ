"""Application configuration, loaded once from the environment."""

from __future__ import annotations

from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_PLACEHOLDER_SECRET = "CHANGE_ME"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    env: str = "local"

    database_url: str
    db_pool_min_size: int = 2
    db_pool_max_size: int = 10

    jwt_secret: str
    jwt_algorithm: str = "HS256"
    jwt_issuer: str = "lifesearch"

    account_token_ttl_minutes: int = 60 * 24 * 30

    otp_ttl_seconds: int = 300
    otp_max_attempts: int = 5
    otp_resend_cooldown_seconds: int = 60

    device_challenge_ttl_seconds: int = 120

    @property
    def is_local(self) -> bool:
        return self.env == "local"

    @model_validator(mode="after")
    def _reject_insecure_production_config(self) -> Settings:
        """Fail fast rather than boot a deployment with a placeholder secret."""
        if not self.is_local and self.jwt_secret == _PLACEHOLDER_SECRET:
            raise ValueError(
                f"JWT_SECRET is still the placeholder while ENV={self.env!r}. "
                "Refusing to start."
            )
        if len(self.jwt_secret) < 32 and not self.is_local:
            raise ValueError("JWT_SECRET must be at least 32 characters outside local.")
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]  # values come from env/.env
