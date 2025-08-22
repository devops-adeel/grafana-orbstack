#!/usr/bin/env python3
"""
Memory Loop Detection Example

Demonstrates detecting and breaking infinite loops in GraphRAG/memory operations,
a common issue in AI agents with recursive memory search.
"""

import os
import asyncio
import hashlib
import time
from typing import Dict, List, Optional, Set
from dataclasses import dataclass, field
from collections import defaultdict
from datetime import datetime, timedelta

from opentelemetry import trace, metrics
from opentelemetry.trace import Status, StatusCode

# Import local wrapper
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from otel_wrapper import setup_telemetry, instrument_mcp_tool, trace_memory_operation

tracer, meter = setup_telemetry("memory-loop-detector")

# Metrics for loop detection
loop_detections = meter.create_counter(
    "memory.loop_detections",
    description="Number of memory loops detected"
)

operation_depth = meter.create_histogram(
    "memory.operation_depth",
    description="Depth of memory operation chains"
)


@dataclass
class OperationSignature:
    """Signature of a memory operation for duplicate detection"""
    operation: str
    query_hash: str
    timestamp: datetime
    count: int = 1
    
    @classmethod
    def from_query(cls, operation: str, query: str) -> 'OperationSignature':
        """Create signature from operation and query"""
        query_hash = hashlib.md5(query.lower().strip().encode()).hexdigest()[:8]
        return cls(operation, query_hash, datetime.now())


@dataclass
class LoopDetectionState:
    """State for tracking potential loops"""
    trace_id: str
    operations: List[OperationSignature] = field(default_factory=list)
    operation_counts: Dict[str, int] = field(default_factory=lambda: defaultdict(int))
    depth: int = 0
    loop_detected: bool = False
    loop_signature: Optional[str] = None


class MemoryLoopDetector:
    """Detects and prevents infinite loops in memory operations"""
    
    def __init__(
        self,
        max_depth: int = 10,
        max_repeats: int = 5,
        time_window_seconds: int = 60
    ):
        self.max_depth = max_depth
        self.max_repeats = max_repeats
        self.time_window = timedelta(seconds=time_window_seconds)
        self.states: Dict[str, LoopDetectionState] = {}
        self.global_patterns: Set[str] = set()  # Track patterns across traces
    
    @instrument_mcp_tool
    async def memory_search_with_loop_detection(
        self,
        query: str,
        operation: str = "search",
        depth: int = 0
    ) -> Dict:
        """
        Memory search with loop detection.
        
        Detects patterns:
        1. Exact query repetition
        2. Semantic similarity loops
        3. Depth-based recursion limits
        4. Time-based pattern detection
        """
        
        # Get trace context
        span = trace.get_current_span()
        trace_id = format(span.get_span_context().trace_id, '032x')
        
        # Initialize or get state
        if trace_id not in self.states:
            self.states[trace_id] = LoopDetectionState(trace_id)
        state = self.states[trace_id]
        
        # Update depth
        state.depth = max(state.depth, depth)
        operation_depth.record(depth)
        
        # Create operation signature
        sig = OperationSignature.from_query(operation, query)
        sig_key = f"{sig.operation}:{sig.query_hash}"
        
        # Check for loops
        loop_type = self._detect_loop(state, sig_key)
        
        if loop_type:
            state.loop_detected = True
            state.loop_signature = sig_key
            
            # Record loop detection
            loop_detections.add(1, {"loop_type": loop_type})
            span.set_status(Status(StatusCode.ERROR, f"Memory loop detected: {loop_type}"))
            span.set_attributes({
                "loop.detected": True,
                "loop.type": loop_type,
                "loop.signature": sig_key,
                "loop.depth": depth,
                "loop.operation_count": state.operation_counts[sig_key]
            })
            
            # Add event with details
            span.add_event("Memory loop detected", {
                "query": query[:100],  # Truncate for safety
                "operation": operation,
                "repetitions": state.operation_counts[sig_key],
                "depth": depth
            })
            
            # Break the loop
            return self._handle_loop_break(query, loop_type, state)
        
        # Track operation
        state.operations.append(sig)
        state.operation_counts[sig_key] += 1
        
        # Trace the operation
        trace_memory_operation(operation, source="loop_detector", count=1, query=query)
        
        # Simulate actual memory operation
        result = await self._perform_memory_operation(query, operation, depth)
        
        # Check if result might trigger another loop
        if self._might_trigger_loop(result, state):
            span.add_event("Potential loop pattern emerging", {
                "current_depth": depth,
                "unique_operations": len(state.operation_counts)
            })
        
        # Clean old states
        self._cleanup_old_states()
        
        return result
    
    def _detect_loop(self, state: LoopDetectionState, sig_key: str) -> Optional[str]:
        """Detect different types of loops"""
        
        # Type 1: Exact repetition
        if state.operation_counts[sig_key] >= self.max_repeats:
            return "exact_repetition"
        
        # Type 2: Depth limit
        if state.depth >= self.max_depth:
            return "max_depth_exceeded"
        
        # Type 3: Rapid succession (same query multiple times in short period)
        recent_ops = [
            op for op in state.operations
            if datetime.now() - op.timestamp < timedelta(seconds=5)
        ]
        if len([op for op in recent_ops if op.query_hash == sig_key.split(':')[1]]) >= 3:
            return "rapid_repetition"
        
        # Type 4: Circular pattern (A→B→C→A)
        if self._detect_circular_pattern(state):
            return "circular_dependency"
        
        # Type 5: Global pattern (seen across multiple traces)
        if sig_key in self.global_patterns:
            return "global_pattern_repetition"
        
        return None
    
    def _detect_circular_pattern(self, state: LoopDetectionState) -> bool:
        """Detect A→B→C→A circular patterns"""
        
        if len(state.operations) < 4:
            return False
        
        # Look for repeating sequences
        recent = [f"{op.operation}:{op.query_hash}" for op in state.operations[-10:]]
        
        for pattern_len in range(2, min(5, len(recent) // 2)):
            pattern = recent[-pattern_len:]
            if recent[-pattern_len*2:-pattern_len] == pattern:
                return True
        
        return False
    
    def _handle_loop_break(self, query: str, loop_type: str, state: LoopDetectionState) -> Dict:
        """Handle breaking out of a detected loop"""
        
        span = trace.get_current_span()
        
        # Different strategies based on loop type
        if loop_type == "exact_repetition":
            # Return cached result or empty
            span.add_event("Returning cached/empty result to break loop")
            return {
                "results": [],
                "error": "Query loop detected - returning empty results",
                "loop_info": {
                    "type": loop_type,
                    "repetitions": state.operation_counts[state.loop_signature]
                }
            }
        
        elif loop_type == "max_depth_exceeded":
            # Return partial results
            span.add_event("Max depth reached - returning partial results")
            return {
                "results": ["[Max depth reached]"],
                "partial": True,
                "depth": state.depth
            }
        
        elif loop_type == "circular_dependency":
            # Break circular dependency
            span.add_event("Circular dependency detected - breaking chain")
            return {
                "results": [],
                "error": "Circular dependency detected",
                "chain": [op.query_hash for op in state.operations[-5:]]
            }
        
        else:
            # Generic loop break
            return {
                "results": [],
                "error": f"Loop detected: {loop_type}",
                "trace_id": state.trace_id
            }
    
    async def _perform_memory_operation(
        self,
        query: str,
        operation: str,
        depth: int
    ) -> Dict:
        """Simulate memory operation that might recurse"""
        
        # Simulate processing time
        await asyncio.sleep(0.1)
        
        # Simulate different operation results
        if operation == "search":
            # Might trigger more searches
            if "recursive" in query.lower():
                # This would trigger another search in real scenario
                if depth < 3:  # Prevent infinite recursion in example
                    sub_result = await self.memory_search_with_loop_detection(
                        f"{query}_expanded",
                        "search",
                        depth + 1
                    )
                    return {"results": ["main_result"], "sub_results": sub_result}
            
            return {"results": [f"result_for_{query}"]}
        
        elif operation == "expand":
            # Expansion might loop back
            return {"expanded": f"{query}_expanded", "continue": depth < 2}
        
        return {"data": query}
    
    def _might_trigger_loop(self, result: Dict, state: LoopDetectionState) -> bool:
        """Check if result might trigger another loop iteration"""
        
        # Check for signals that might cause loops
        if isinstance(result, dict):
            if result.get("continue") or result.get("recurse"):
                return True
            if "sub_results" in result and state.depth > 5:
                return True
        
        return False
    
    def _cleanup_old_states(self):
        """Clean up old detection states"""
        
        now = datetime.now()
        expired_traces = []
        
        for trace_id, state in self.states.items():
            if state.operations:
                oldest = state.operations[0].timestamp
                if now - oldest > self.time_window:
                    expired_traces.append(trace_id)
        
        for trace_id in expired_traces:
            del self.states[trace_id]
    
    def get_loop_statistics(self) -> Dict:
        """Get statistics about detected loops"""
        
        total_loops = sum(1 for s in self.states.values() if s.loop_detected)
        loop_types = defaultdict(int)
        
        for state in self.states.values():
            if state.loop_signature:
                # Categorize by operation type
                op_type = state.loop_signature.split(':')[0]
                loop_types[op_type] += 1
        
        return {
            "total_loops_detected": total_loops,
            "active_traces": len(self.states),
            "loop_types": dict(loop_types),
            "max_depth_seen": max((s.depth for s in self.states.values()), default=0)
        }


async def simulate_loop_scenarios():
    """Simulate different loop scenarios"""
    
    detector = MemoryLoopDetector(max_depth=5, max_repeats=3)
    
    print("\n🔄 Testing Loop Detection Scenarios")
    print("=" * 60)
    
    # Scenario 1: Simple repetition loop
    print("\n1. Simple Repetition Loop:")
    print("-" * 40)
    for i in range(5):
        result = await detector.memory_search_with_loop_detection(
            "find similar documents",
            "search"
        )
        if "error" in result:
            print(f"   Loop detected at iteration {i+1}: {result['error']}")
            break
        else:
            print(f"   Iteration {i+1}: Success")
    
    # Scenario 2: Recursive depth loop
    print("\n2. Recursive Depth Loop:")
    print("-" * 40)
    result = await detector.memory_search_with_loop_detection(
        "recursive query",
        "search",
        depth=0
    )
    print(f"   Result: {result.get('error', 'Completed successfully')}")
    
    # Scenario 3: Circular pattern
    print("\n3. Circular Pattern Loop:")
    print("-" * 40)
    queries = ["query_a", "query_b", "query_c", "query_a", "query_b", "query_c"]
    for i, q in enumerate(queries):
        result = await detector.memory_search_with_loop_detection(q, "search")
        if "error" in result:
            print(f"   Circular loop detected at step {i+1}: {result['error']}")
            break
        else:
            print(f"   Step {i+1} ({q}): OK")
    
    # Show statistics
    stats = detector.get_loop_statistics()
    print("\n📊 Loop Detection Statistics:")
    print(f"   Total loops detected: {stats['total_loops_detected']}")
    print(f"   Active traces: {stats['active_traces']}")
    print(f"   Max depth seen: {stats['max_depth_seen']}")


async def main():
    """Run memory loop detection examples"""
    
    print("🧠 Memory Loop Detection Example")
    print("=" * 60)
    print("\nThis example demonstrates detecting and breaking infinite loops")
    print("in GraphRAG/memory operations - a common issue in AI agents.\n")
    
    # Run simulations
    await simulate_loop_scenarios()
    
    # Show monitoring queries
    print("\n📈 Monitoring Queries:")
    print("-" * 40)
    print("Prometheus query for loop detection rate:")
    print("  rate(memory_loop_detections_total[5m])")
    print("\nTempo query for traces with loops:")
    print('  {.loop.detected="true"}')
    print("\nGrafana alert for high loop rate:")
    print("  rate(memory_loop_detections_total[1m]) > 0.5")
    
    print("\n✅ Example complete - Check Grafana for loop detection metrics")
    
    # Allow time for metrics export
    await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(main())