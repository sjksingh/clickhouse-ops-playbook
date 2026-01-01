# Performance Analysis Checklist
**Use this for ANY database/system performance problem**

---

## Phase 1: OBSERVE (Gather Facts)

### [ ] Get the raw data, not summaries
```bash
# Don't trust dashboards alone - look at query logs
ch_query "SELECT * FROM system.query_log WHERE ... ORDER BY query_duration_ms DESC LIMIT 100"

# Look at individual executions, not just averages
# Outliers tell the story
```

### [ ] Establish the baseline
```
- What's NORMAL performance?
  - P50: _____ P95: _____ P99: _____
  - Memory: _____ CPU: _____ I/O: _____
  
- What's INCIDENT performance?
  - P50: _____ P95: _____ P99: _____
  - Memory: _____ CPU: _____ I/O: _____
  
- Degradation factor: _____x slower
```

### [ ] Build a timeline
```
Time    | Event
--------|--------------------------------------------------
HH:MM   | Normal operation (baseline metrics)
HH:MM   | First degradation noticed (what triggered it?)
HH:MM   | Peak severity (what was happening?)
HH:MM   | Recovery (what changed?)
```

### [ ] Collect system context
```bash
# What ELSE was happening?
- Other queries running? How many?
- Background operations (merges, replication)?
- System resources (disk, memory, network)?
- External factors (batch jobs, deployments)?
```

---

## Phase 2: ORIENT (Build Understanding)

### [ ] Question the obvious
```
Initial hypothesis: ___________________________

Challenge it:
- What evidence supports this? ________________
- What evidence contradicts this? _____________
- Could this be a symptom, not the cause? _____
```

### [ ] Look for contradictions
```
Data point 1: _______________
Data point 2: _______________

Do they match? If not, why?
___________________________________________
```

### [ ] Apply the "Five Whys"
```
1. Why is the system slow?
   Answer: ___________
   
2. Why does that cause slowness?
   Answer: ___________
   
3. Why is that happening?
   Answer: ___________
   
4. Why wasn't this prevented?
   Answer: ___________
   
5. Why don't we have monitoring for this?
   Answer: ___________ (ROOT CAUSE)
```

### [ ] Check resource utilization
```
During incident vs baseline:

Resource    | Baseline | Incident | Conclusion
------------|----------|----------|------------------------
CPU         | ____%    | ____%    | Saturated? Yes/No
Memory      | ___GB    | ___GB    | Pressure? Yes/No
Disk I/O    | ___MB/s  | ___MB/s  | Saturated? Yes/No
Network     | ___MB/s  | ___MB/s  | Saturated? Yes/No

Which resource is the bottleneck? ___________
```

### [ ] Look for patterns
```
Does this happen:
[ ] At specific times? (When? ________)
[ ] With specific queries? (Which? ________)
[ ] After specific events? (What? ________)
[ ] Randomly? (How often? ________)

Pattern reveals: ___________________________
```

---

## Phase 3: DECIDE (Form Hypothesis)

### [ ] State your hypothesis clearly
```
ROOT CAUSE: ___________________________________

MECHANISM: How does this cause the symptoms?
_______________________________________________

EVIDENCE: What proves this is the cause?
- [ ] ________________________________________
- [ ] ________________________________________
- [ ] ________________________________________

DISPROOF: What would prove this is NOT the cause?
- [ ] ________________________________________
- [ ] ________________________________________
```

### [ ] Consider alternatives
```
Alternative explanation 1: ___________________
Ruled out because: __________________________

Alternative explanation 2: ___________________
Ruled out because: __________________________

If unsure, what data would tell you? _________
```

### [ ] Predict the fix
```
If my hypothesis is correct, then:
- Fixing X should improve Y by Z%
- We should see A change to B
- The problem should stop when C happens

Can I test this safely? Yes/No
```

---

## Phase 4: ACT (Fix & Prevent)

### [ ] Immediate action (stop the bleeding)
```
What can I do RIGHT NOW (5-30 min) to:
1. ________________________________________
2. ________________________________________
3. ________________________________________

Risk: What could go wrong? _________________
Rollback plan: _____________________________
```

### [ ] Short-term fix (this week)
```
What can I do in 1-7 days to:
1. ________________________________________
2. ________________________________________
3. ________________________________________

Expected improvement: _____%
How will I measure success? ________________
```

### [ ] Long-term solution (this month/quarter)
```
What architectural changes prevent this?
1. ________________________________________
2. ________________________________________
3. ________________________________________

Investment required: _______ (time/money)
ROI: ______________________________________
```

### [ ] Monitoring & alerting
```
What should we monitor to catch this early?
1. Metric: __________ Threshold: __________
2. Metric: __________ Threshold: __________
3. Metric: __________ Threshold: __________

Alert when: ________________________________
Alert whom: ________________________________
```

---

## Phase 5: VERIFY (Did It Work?)

### [ ] Measure the improvement
```
Metric          | Before | After | Improvement
----------------|--------|-------|-------------
Latency (P95)   | ____   | ____  | ____%
Error rate      | ____   | ____  | ____%
Resource usage  | ____   | ____  | ____%

Did we hit our goal? Yes/No
```

### [ ] Check for side effects
```
Did the fix cause:
- [ ] New errors? (What? __________________)
- [ ] Performance regression elsewhere?
- [ ] Increased resource usage?
- [ ] User complaints?

If yes, what's the mitigation? _____________
```

### [ ] Update documentation
```
- [ ] Runbook updated with this scenario
- [ ] Monitoring dashboard includes new metrics
- [ ] Team wiki has post-mortem
- [ ] Alerts configured
- [ ] Knowledge shared with team
```

---

## Meta-Questions (For Every Analysis)

### [ ] Systemic thinking
```
Is this:
[ ] One-time incident? (Fix and move on)
[ ] Recurring pattern? (Need architectural change)
[ ] Symptom of capacity limits? (Need to scale)
[ ] Monitoring gap? (Need better visibility)

What does this tell us about our system? ______
```

### [ ] Business impact
```
Who was affected? ___________________________
For how long? _______________________________
What couldn't they do? ______________________
Cost (time/money/reputation)? _______________

How do we prevent this impact in future? ______
```

### [ ] Communication
```
Who needs to know about this?
- [ ] My team (when? ____________)
- [ ] Other teams (who? ____________)
- [ ] Leadership (how much detail? ____________)
- [ ] Customers (what do we say? ____________)

What's the key message? _____________________
```

---

## Red Flags: When to Escalate

Escalate immediately if:
- [ ] Incident is ongoing and worsening
- [ ] User-facing service is down
- [ ] Data integrity at risk
- [ ] You're stuck and need help
- [ ] Solution requires architectural changes
- [ ] Impact exceeds your authority level

---


**Rate yourself (1-5 scale):**

[ ] Data-driven: Did I look at raw data, not just dashboards?
    1 (dashboard only) - 5 (deep forensics)
    
[ ] Root cause: Did I find mechanism, not just symptoms?
    1 (surface level) - 5 (physics/reality)
    
[ ] Systemic: Did I think about prevention, not just fixes?
    1 (one-time fix) - 5 (architectural change)
    
[ ] Communication: Did I document and share learnings?
    1 (kept to myself) - 5 (post-mortem + runbook)
    
[ ] Business impact: Did I quantify user/business effect?
    1 (no mention) - 5 (clear cost/impact)

**Target for principal level: 4-5 on all dimensions**

---

## Examples of Good vs. Great Analysis

### ❌ Staff-Level Analysis
```
"The query is slow because it scans too much data. 
I added an index. 
It's faster now."
```

### ✅ Principal-Level Analysis
```
"The query degraded from 8s to 500s on Dec 28, 12PM-5PM.

Root cause: I/O saturation from concurrent merge storms 
(428 operations, 189GB merged) during business hours.

Evidence:
- Memory usage dropped (queries waiting, not computing)
- Disk I/O correlation with merge activity
- Self-healed when merges completed

Immediate: Enabled external GROUP BY (prevent OOM)
Short-term: Throttle merges during business hours
Long-term: Separate analytics shard, read replicas

Monitoring: Alert on merge ops >2000/hr, query P95 >15s

Impact: 100 queries affected, 8,300s cumulative latency
Prevention: Will reduce incident frequency by 90%

Post-mortem published, team briefed, runbook updated."
```

**The difference:**
- Root cause vs symptom
- Timeline and evidence
- Multi-tier solutions
- Monitoring and prevention
- Business impact quantified
- Knowledge shared

---

## Additional Resources

**Books:**
- "The Field Guide to Understanding 'Human Error'" (Sidney Dekker)
- "Thinking in Systems" (Donella Meadows)
- "Site Reliability Engineering" (Google)

**Practice:**
- Review 1 incident per week
- Write mini post-mortems
- Build your mental models
- Share learnings with team

**Remember:**
Principal engineers aren't just faster debuggers.
They're system thinkers who prevent problems before they happen.

---

*Use this checklist for EVERY performance investigation*
