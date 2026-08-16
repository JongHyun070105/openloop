class ExternalIntegrationError(RuntimeError):
    """Safe, provider-neutral failure surfaced without request or credential data."""


class ExternalIntegrationTimeout(ExternalIntegrationError):
    pass
