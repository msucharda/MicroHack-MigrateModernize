# Multi-stage build for ContosoUniversity .NET Framework 4.8 Application
# Stage 1: Build the application
FROM mcr.microsoft.com/dotnet/framework/sdk:4.8-windowsservercore-ltsc2022 AS build

WORKDIR /app

# Copy project files
COPY ContosoUniversity.sln .
COPY ContosoUniversity.csproj .
COPY packages.config .

# Restore NuGet packages
RUN nuget restore ContosoUniversity.sln

# Copy source code
COPY . .

# Build the application
RUN msbuild ContosoUniversity.csproj /p:Configuration=Release /p:DeployOnBuild=true /p:PublishProfile=FolderProfile /p:OutputPath=C:\publish

# Stage 2: Create the runtime image
FROM mcr.microsoft.com/dotnet/framework/aspnet:4.8-windowsservercore-ltsc2022

# Enable IIS features if needed
RUN powershell -Command Add-WindowsFeature Web-Asp-Net45

WORKDIR /inetpub/wwwroot

# Copy published application from build stage
COPY --from=build C:/publish .

# Set up application pool to use Integrated Pipeline mode
RUN powershell -Command \
    Import-Module WebAdministration; \
    Set-ItemProperty 'IIS:\AppPools\DefaultAppPool' -Name managedRuntimeVersion -Value 'v4.0'; \
    Set-ItemProperty 'IIS:\AppPools\DefaultAppPool' -Name managedPipelineMode -Value 'Integrated'

# Expose HTTP port
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD powershell -Command "try { \$response = Invoke-WebRequest -Uri http://localhost -UseBasicParsing -TimeoutSec 3; if (\$response.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }"

# Note: Connection strings and configuration should be provided via environment variables
# Update Web.config or use Web.Release.config transformations to read from environment variables
