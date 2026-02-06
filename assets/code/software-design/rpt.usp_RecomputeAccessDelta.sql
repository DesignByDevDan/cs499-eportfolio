CREATE PROCEDURE [rpt].[usp_RecomputeAccessDelta]
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO rpt.AccessDelta (EmployeeID, CardNumber, [Action], Reason)
    SELECT
        n.EmployeeID,
        n.CardNumber,
        N'RESTRICT' AS [Action],
        CONCAT(N'Non-compliant requirement(s): ', STRING_AGG(n.RequirementCode, N', '))
    FROM rpt.vw_NonCompliant AS n
    GROUP BY n.EmployeeID, n.CardNumber;
END;
