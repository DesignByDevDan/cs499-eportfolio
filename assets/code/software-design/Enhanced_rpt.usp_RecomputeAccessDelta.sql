/* Milestone Thee Enhancments */ 

   Project: Access Compliance Reporting
CREATE OR ALTER PROCEDURE [rpt].[usp_RecomputeAccessDelta]
AS
BEGIN
    /*
        Name:       rpt.usp_RecomputeAccessDelta
        Purpose:    Recompute RESTRICT access deltas for employees/cards that are currently non-compliant.
                    Inserts delta rows into rpt.AccessDelta with an aggregated Reason message.

        Inputs:     None (uses rpt.vw_NonCompliant as the source of truth)
        Outputs:    Rows inserted into rpt.AccessDelta

        Assumptions:
          - rpt.vw_NonCompliant returns at minimum: EmployeeID, CardNumber, RequirementCode.
          - Each (EmployeeID, CardNumber) may have multiple RequirementCode rows.
          - This procedure is intended to be re-runnable (idempotent behavior is enforced by deleting
            prior RESTRICT rows for the same EmployeeID/CardNumber before inserting refreshed results).

        Change Log:
          - 2026-01-23: Refactored into phases, added defensive checks, idempotent delete+insert,
                        transaction, and TRY/CATCH error handling.
    */

    SET NOCOUNT ON;
    SET XACT_ABORT ON; -- if a runtime error occurs within a transaction, SQL Server will automatically roll it back

    -------------------------------------------------------------------------
    -- Phase 0: Defensive validation (fail fast with clear errors)
    -------------------------------------------------------------------------
    IF OBJECT_ID(N'rpt.vw_NonCompliant', N'V') IS NULL
    BEGIN
        THROW 51000, 'Required view rpt.vw_NonCompliant does not exist. Cannot recompute access delta.', 1;
    END;

    IF OBJECT_ID(N'rpt.AccessDelta', N'U') IS NULL
    BEGIN
        THROW 51001, 'Required table rpt.AccessDelta does not exist. Cannot recompute access delta.', 1;
    END;

    -------------------------------------------------------------------------
    -- Phase 1: Stage computed results (improves readability and testability)
    -------------------------------------------------------------------------
    DROP TABLE IF EXISTS #NonCompliantAgg;

    CREATE TABLE #NonCompliantAgg
    (
        EmployeeID      NVARCHAR(50)  NOT NULL,
        CardNumber      NVARCHAR(50)  NOT NULL,
        [Action]        NVARCHAR(20)  NOT NULL,
        Reason          NVARCHAR(4000) NOT NULL
    );

    INSERT INTO #NonCompliantAgg (EmployeeID, CardNumber, [Action], Reason)
    SELECT
        n.EmployeeID,
        n.CardNumber,
        N'RESTRICT' AS [Action],
        CONCAT(N'Non-compliant requirement(s): ', STRING_AGG(CONVERT(NVARCHAR(200), n.RequirementCode), N', '))
    FROM rpt.vw_NonCompliant AS n
    WHERE
        n.EmployeeID IS NOT NULL
        AND n.CardNumber IS NOT NULL
        AND n.RequirementCode IS NOT NULL
    GROUP BY
        n.EmployeeID,
        n.CardNumber;

    -------------------------------------------------------------------------
    -- Phase 2: Validate staged results (defensive programming)
    -------------------------------------------------------------------------
    DECLARE @ToInsert INT = (SELECT COUNT(1) FROM #NonCompliantAgg);

    -- If there is no non-compliant data, there is nothing to insert.
    -- This is not an error condition; it is a valid “all compliant” outcome.
    IF @ToInsert = 0
    BEGIN
        RETURN;
    END;

    -------------------------------------------------------------------------
    -- Phase 3: Apply changes to target table (idempotent + transactional)
    -------------------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        /*
            Idempotency strategy:
              - Remove prior RESTRICT rows for EmployeeID/CardNumber pairs we are about to reinsert.
              - This prevents duplicates across runs while preserving other actions (if any exist).
              - If AccessDelta is intended to be a full audit history table, you could replace this
                with a RunID pattern instead; this implementation prioritizes “current delta state.”
        */
        DELETE d
        FROM rpt.AccessDelta AS d
        INNER JOIN #NonCompliantAgg AS s
            ON s.EmployeeID = d.EmployeeID
           AND s.CardNumber = d.CardNumber
        WHERE d.[Action] = N'RESTRICT';

        INSERT INTO rpt.AccessDelta (EmployeeID, CardNumber, [Action], Reason)
        SELECT
            s.EmployeeID,
            s.CardNumber,
            s.[Action],
            s.Reason
        FROM #NonCompliantAgg AS s;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        /*
            Provide actionable troubleshooting info without forcing the caller to dig.
            THROW re-raises the error with original context when used without parameters,
            but here we attach clearer procedure-level context.
        */
        DECLARE
            @ErrMsg     NVARCHAR(2048) = ERROR_MESSAGE(),
            @ErrNum     INT            = ERROR_NUMBER(),
            @ErrState   INT            = ERROR_STATE(),
            @ErrLine    INT            = ERROR_LINE();

        THROW 51002,
              CONCAT('usp_RecomputeAccessDelta failed. Error ', @ErrNum, ' at line ', @ErrLine, ': ', @ErrMsg),
              @ErrState;
    END CATCH
END;
GO

