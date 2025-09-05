#!/usr/bin/env python3
"""
Local Model Cost Tracker for OpenTelemetry
Tracks resource usage for local LLMs (Ollama, etc.) as "costs"
Converts GPU memory, inference time, and model size into comparable metrics
"""

import os
import time
import psutil
import logging
from typing import Dict, Any, Optional, Tuple
from dataclasses import dataclass, field
from collections import deque
from datetime import datetime, timedelta

try:
    from opentelemetry import trace, metrics
    from opentelemetry.metrics import CallbackOptions, Observation
    OTEL_AVAILABLE = True
except ImportError:
    OTEL_AVAILABLE = False
    logging.warning("OpenTelemetry not available. Metrics will not be exported.")

logger = logging.getLogger(__name__)


@dataclass
class ModelMetrics:
    """Metrics for a local model inference"""
    model_name: str
    inference_ms: float
    tokens_generated: int
    memory_mb: float
    gpu_memory_mb: Optional[float] = None
    model_size_gb: Optional[float] = None
    timestamp: datetime = field(default_factory=datetime.utcnow)
    
    @property
    def cost_units(self) -> float:
        """
        Calculate "cost" in arbitrary units based on resource usage.
        This helps compare different models and configurations.
        
        Cost formula:
        - Base cost = inference_ms / 1000 (seconds of compute)
        - Memory multiplier = memory_mb / 1000 (GB of RAM)
        - GPU multiplier = gpu_memory_mb / 1000 (GB of VRAM) * 2 (GPU is more expensive)
        - Size multiplier = model_size_gb * 0.5 (larger models cost more to load)
        """
        base_cost = self.inference_ms / 1000.0
        
        # Memory cost (RAM)
        memory_cost = (self.memory_mb / 1000.0) * base_cost
        
        # GPU cost (more expensive than RAM)
        gpu_cost = 0
        if self.gpu_memory_mb:
            gpu_cost = (self.gpu_memory_mb / 1000.0) * base_cost * 2
        
        # Model size cost (loading overhead)
        size_cost = 0
        if self.model_size_gb:
            size_cost = self.model_size_gb * 0.5
        
        total_cost = base_cost + memory_cost + gpu_cost + size_cost
        
        # Normalize per token for fair comparison
        if self.tokens_generated > 0:
            return total_cost / self.tokens_generated
        return total_cost
    
    @property
    def tokens_per_second(self) -> float:
        """Calculate token generation rate"""
        if self.inference_ms > 0:
            return (self.tokens_generated / self.inference_ms) * 1000
        return 0


class LocalModelTracker:
    """
    Tracks resource usage for local LLM models and exports metrics via OpenTelemetry.
    Provides cost-like metrics for resource consumption rather than monetary costs.
    """
    
    # Model size estimates (in GB) for common models
    MODEL_SIZES = {
        "llama3": 4.0,
        "llama3:70b": 40.0,
        "llama2": 3.8,
        "llama2:13b": 7.4,
        "llama2:70b": 40.0,
        "mistral": 4.1,
        "mixtral": 26.0,
        "deepseek-r1": 8.0,
        "deepseek-r1:70b": 40.0,
        "codellama": 3.8,
        "phi": 1.6,
        "phi3": 2.0,
        "gemma": 5.0,
        "gemma2": 5.0,
    }
    
    def __init__(self, 
                 window_seconds: int = 300,
                 export_interval_seconds: int = 30):
        """
        Initialize local model tracker.
        
        Args:
            window_seconds: Time window for metric aggregation
            export_interval_seconds: How often to export metrics
        """
        self.window_seconds = window_seconds
        self.export_interval = export_interval_seconds
        
        # Metric storage
        self.recent_metrics: deque = deque(maxlen=1000)
        self.model_stats: Dict[str, Dict[str, Any]] = {}
        
        # Current resource usage
        self.current_memory_mb = 0
        self.current_gpu_memory_mb = 0
        self.active_models: set = set()
        
        # Set up OpenTelemetry metrics if available
        if OTEL_AVAILABLE:
            self._setup_metrics()
        
        logger.info(f"LocalModelTracker initialized with {window_seconds}s window")
    
    def _setup_metrics(self):
        """Set up OpenTelemetry metrics"""
        meter = metrics.get_meter("local_model_tracker")
        
        # Cost metric (aggregated)
        self.cost_histogram = meter.create_histogram(
            "gen_ai.local_model.cost_units",
            description="Resource cost units per token for local models",
            unit="units/token",
        )
        
        # Performance metrics
        self.inference_histogram = meter.create_histogram(
            "gen_ai.local_model.inference_ms", 
            description="Inference time for local models",
            unit="ms",
        )
        
        self.tokens_per_sec_histogram = meter.create_histogram(
            "gen_ai.local_model.tokens_per_second",
            description="Token generation rate for local models",
            unit="tokens/s",
        )
        
        # Resource metrics (gauges via callbacks)
        meter.create_observable_gauge(
            "gen_ai.local_model.memory_mb",
            callbacks=[self._get_memory_usage],
            description="Current memory usage for local models",
            unit="MB",
        )
        
        meter.create_observable_gauge(
            "gen_ai.local_model.gpu_memory_mb",
            callbacks=[self._get_gpu_memory_usage],
            description="Current GPU memory usage for local models",
            unit="MB",
        )
        
        meter.create_observable_gauge(
            "gen_ai.local_model.active_models",
            callbacks=[self._get_active_model_count],
            description="Number of active local models",
            unit="models",
        )
    
    def _get_memory_usage(self, options: CallbackOptions) -> list[Observation]:
        """Callback for memory usage metric"""
        return [Observation(self.current_memory_mb, {})]
    
    def _get_gpu_memory_usage(self, options: CallbackOptions) -> list[Observation]:
        """Callback for GPU memory usage metric"""
        return [Observation(self.current_gpu_memory_mb, {})]
    
    def _get_active_model_count(self, options: CallbackOptions) -> list[Observation]:
        """Callback for active model count"""
        return [Observation(len(self.active_models), {})]
    
    def track_inference(self,
                        model_name: str,
                        inference_ms: float,
                        tokens_generated: int,
                        memory_mb: Optional[float] = None,
                        gpu_memory_mb: Optional[float] = None) -> ModelMetrics:
        """
        Track a model inference and calculate costs.
        
        Args:
            model_name: Name of the model (e.g., "llama3", "mistral")
            inference_ms: Time taken for inference in milliseconds
            tokens_generated: Number of tokens generated
            memory_mb: RAM usage in MB (will be measured if not provided)
            gpu_memory_mb: GPU memory usage in MB
            
        Returns:
            ModelMetrics with calculated costs
        """
        # Measure memory if not provided
        if memory_mb is None:
            memory_mb = self._measure_memory()
        
        # Estimate model size
        model_size_gb = self._estimate_model_size(model_name)
        
        # Create metrics object
        metrics_obj = ModelMetrics(
            model_name=model_name,
            inference_ms=inference_ms,
            tokens_generated=tokens_generated,
            memory_mb=memory_mb,
            gpu_memory_mb=gpu_memory_mb,
            model_size_gb=model_size_gb,
        )
        
        # Store metrics
        self.recent_metrics.append(metrics_obj)
        self.active_models.add(model_name)
        
        # Update current resource usage
        self.current_memory_mb = memory_mb
        if gpu_memory_mb:
            self.current_gpu_memory_mb = gpu_memory_mb
        
        # Update model statistics
        self._update_model_stats(metrics_obj)
        
        # Export metrics if OpenTelemetry is available
        if OTEL_AVAILABLE:
            self._export_metrics(metrics_obj)
        
        logger.debug(
            f"Tracked inference: {model_name} - {inference_ms:.1f}ms, "
            f"{tokens_generated} tokens, cost: {metrics_obj.cost_units:.3f} units/token"
        )
        
        return metrics_obj
    
    def _measure_memory(self) -> float:
        """Measure current process memory usage"""
        process = psutil.Process()
        memory_info = process.memory_info()
        return memory_info.rss / (1024 * 1024)  # Convert to MB
    
    def _estimate_model_size(self, model_name: str) -> float:
        """Estimate model size based on name"""
        # Check exact match first
        if model_name in self.MODEL_SIZES:
            return self.MODEL_SIZES[model_name]
        
        # Check for partial matches (e.g., "llama3:latest" -> "llama3")
        for known_model, size in self.MODEL_SIZES.items():
            if known_model in model_name:
                return size
        
        # Default estimate based on common patterns
        if "70b" in model_name.lower():
            return 40.0
        elif "13b" in model_name.lower():
            return 7.5
        elif "7b" in model_name.lower():
            return 4.0
        elif "3b" in model_name.lower():
            return 2.0
        else:
            return 4.0  # Default estimate
    
    def _update_model_stats(self, metrics: ModelMetrics):
        """Update aggregated statistics for a model"""
        if metrics.model_name not in self.model_stats:
            self.model_stats[metrics.model_name] = {
                "total_inferences": 0,
                "total_tokens": 0,
                "total_cost_units": 0,
                "avg_inference_ms": 0,
                "avg_tokens_per_sec": 0,
                "max_memory_mb": 0,
                "max_gpu_memory_mb": 0,
            }
        
        stats = self.model_stats[metrics.model_name]
        stats["total_inferences"] += 1
        stats["total_tokens"] += metrics.tokens_generated
        stats["total_cost_units"] += metrics.cost_units * metrics.tokens_generated
        
        # Update averages (running average)
        n = stats["total_inferences"]
        stats["avg_inference_ms"] = (
            (stats["avg_inference_ms"] * (n - 1) + metrics.inference_ms) / n
        )
        stats["avg_tokens_per_sec"] = (
            (stats["avg_tokens_per_sec"] * (n - 1) + metrics.tokens_per_second) / n
        )
        
        # Update maximums
        stats["max_memory_mb"] = max(stats["max_memory_mb"], metrics.memory_mb)
        if metrics.gpu_memory_mb:
            stats["max_gpu_memory_mb"] = max(
                stats["max_gpu_memory_mb"], 
                metrics.gpu_memory_mb
            )
    
    def _export_metrics(self, metrics: ModelMetrics):
        """Export metrics to OpenTelemetry"""
        attributes = {
            "model": metrics.model_name,
            "has_gpu": metrics.gpu_memory_mb is not None,
        }
        
        # Record histograms
        self.cost_histogram.record(metrics.cost_units, attributes)
        self.inference_histogram.record(metrics.inference_ms, attributes)
        self.tokens_per_sec_histogram.record(metrics.tokens_per_second, attributes)
    
    def get_model_comparison(self) -> Dict[str, Dict[str, Any]]:
        """
        Get comparison of all tracked models.
        
        Returns:
            Dictionary with model names as keys and performance metrics as values
        """
        comparison = {}
        
        for model_name, stats in self.model_stats.items():
            comparison[model_name] = {
                "avg_cost_per_token": stats["total_cost_units"] / max(stats["total_tokens"], 1),
                "avg_tokens_per_sec": stats["avg_tokens_per_sec"],
                "avg_inference_ms": stats["avg_inference_ms"],
                "total_inferences": stats["total_inferences"],
                "max_memory_gb": stats["max_memory_mb"] / 1024,
                "max_gpu_memory_gb": stats["max_gpu_memory_mb"] / 1024,
            }
        
        return comparison
    
    def get_cost_trend(self, model_name: str, hours: float = 1) -> Tuple[float, float]:
        """
        Get cost trend for a model over time.
        
        Args:
            model_name: Model to analyze
            hours: Hours of history to analyze
            
        Returns:
            Tuple of (current_cost, trend_percentage)
        """
        cutoff = datetime.utcnow() - timedelta(hours=hours)
        
        # Filter metrics for this model and time window
        model_metrics = [
            m for m in self.recent_metrics
            if m.model_name == model_name and m.timestamp >= cutoff
        ]
        
        if len(model_metrics) < 2:
            return 0, 0
        
        # Calculate average cost for first and second half
        mid_point = len(model_metrics) // 2
        first_half = model_metrics[:mid_point]
        second_half = model_metrics[mid_point:]
        
        avg_cost_first = sum(m.cost_units for m in first_half) / len(first_half)
        avg_cost_second = sum(m.cost_units for m in second_half) / len(second_half)
        
        # Calculate trend
        if avg_cost_first > 0:
            trend = ((avg_cost_second - avg_cost_first) / avg_cost_first) * 100
        else:
            trend = 0
        
        return avg_cost_second, trend
    
    def suggest_optimization(self, model_name: str) -> list[str]:
        """
        Suggest optimizations based on tracked metrics.
        
        Args:
            model_name: Model to optimize
            
        Returns:
            List of optimization suggestions
        """
        suggestions = []
        
        if model_name not in self.model_stats:
            return ["No data available for this model"]
        
        stats = self.model_stats[model_name]
        
        # Check token generation rate
        if stats["avg_tokens_per_sec"] < 10:
            suggestions.append("Consider using a smaller model for faster generation")
        
        # Check memory usage
        if stats["max_memory_mb"] > 8192:  # 8GB
            suggestions.append("High memory usage - consider quantization (4-bit or 8-bit)")
        
        # Check GPU usage
        if stats["max_gpu_memory_mb"] > 6144:  # 6GB VRAM
            suggestions.append("GPU memory pressure - use smaller batch size or model")
        
        # Check inference time
        if stats["avg_inference_ms"] > 5000:  # 5 seconds
            suggestions.append("Slow inference - try GPU acceleration or smaller model")
        
        # Model-specific suggestions
        if "70b" in model_name.lower():
            suggestions.append("Large model detected - consider 7B or 13B variant for most tasks")
        
        return suggestions if suggestions else ["Model performing well - no optimizations needed"]


# Example usage and integration with OpenTelemetry
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    
    # Initialize tracker
    tracker = LocalModelTracker()
    
    # Simulate some inferences
    import random
    
    models = ["llama3", "mistral", "deepseek-r1"]
    
    for _ in range(10):
        model = random.choice(models)
        inference_ms = random.uniform(100, 2000)
        tokens = random.randint(10, 200)
        memory = random.uniform(2000, 6000)
        
        metrics = tracker.track_inference(
            model_name=model,
            inference_ms=inference_ms,
            tokens_generated=tokens,
            memory_mb=memory,
        )
        
        print(f"{model}: {metrics.cost_units:.3f} units/token, "
              f"{metrics.tokens_per_second:.1f} tokens/s")
    
    # Show comparison
    comparison = tracker.get_model_comparison()
    print("\nModel Comparison:")
    for model, stats in comparison.items():
        print(f"  {model}: {stats['avg_cost_per_token']:.3f} units/token, "
              f"{stats['avg_tokens_per_sec']:.1f} tokens/s")
    
    # Get optimization suggestions
    for model in models:
        suggestions = tracker.suggest_optimization(model)
        print(f"\nOptimizations for {model}:")
        for suggestion in suggestions:
            print(f"  - {suggestion}")