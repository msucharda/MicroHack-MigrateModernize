# Multi-stage build for AssetManager Worker Service
# Stage 1: Build the application
FROM maven:3.9-eclipse-temurin-21-jammy AS build

WORKDIR /app

# Copy parent pom first
COPY pom.xml ../pom.xml

# Copy worker module pom
COPY worker/pom.xml ./pom.xml

# Download dependencies (this layer will be cached if pom.xml doesn't change)
RUN mvn dependency:go-offline -B -f ./pom.xml

# Copy source code
COPY worker/src ./src

# Build the application
RUN mvn clean package -DskipTests -B

# Stage 2: Create the runtime image
FROM eclipse-temurin:21-jre-jammy

# Create a non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Copy the jar from build stage
COPY --from=build /app/target/assets-manager-worker-*.jar app.jar

# Change ownership to non-root user
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Set JVM options for containerized environment
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"

# Run the worker application
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
