
CREATE TABLE INTERNAL.LABELS if not exists (name string, group_name string null, group_rank number, label_created_at timestamp, condition string, enabled boolean, label_modified_at timestamp);

CREATE TABLE INTERNAL.PREDEFINED_LABELS if not exists (name string, group_name string null, group_rank number, label_created_at timestamp, condition string, enabled boolean, label_modified_at timestamp);

CREATE OR REPLACE PROCEDURE INTERNAL.MIGRATE_LABELS_TABLE()
RETURNS OBJECT
AS
BEGIN
    -- Add modified at column
    IF (NOT EXISTS(SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'INTERNAL' AND TABLE_NAME = 'LABELS' AND COLUMN_NAME = 'LABEL_MODIFIED_AT')) THEN
        ALTER TABLE INTERNAL.LABELS ADD COLUMN LABEL_MODIFIED_AT TIMESTAMP;
        UPDATE INTERNAL.LABELS SET LABEL_MODIFIED_AT = CURRENT_TIMESTAMP WHERE LABEL_MODIFIED_AT IS NULL;
    END IF;

    -- Recreate the view to avoid number of column mis-match. Should be cheap and only run on install/upgrade, so it's OK
    -- if we run this unnecessarily.
    CREATE OR REPLACE VIEW CATALOG.LABELS COPY GRANTS AS SELECT * FROM INTERNAL.LABELS;
EXCEPTION
    WHEN OTHER THEN
        SYSTEM$LOG('error', 'Failed to migrate labels table. ' || :SQLCODE || ': ' || :SQLERRM);
        raise;
END;

CREATE OR REPLACE PROCEDURE INTERNAL.MIGRATE_PREDEFINED_LABELS_TABLE()
RETURNS OBJECT
AS
BEGIN
    -- Add modified at column
    IF (NOT EXISTS(SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'INTERNAL' AND TABLE_NAME = 'PREDEFINED_LABELS' AND COLUMN_NAME = 'LABEL_MODIFIED_AT')) THEN
        ALTER TABLE INTERNAL.PREDEFINED_LABELS ADD COLUMN LABEL_MODIFIED_AT TIMESTAMP;
        UPDATE INTERNAL.PREDEFINED_LABELS SET LABEL_MODIFIED_AT = CURRENT_TIMESTAMP WHERE LABEL_MODIFIED_AT IS NULL;
    END IF;

EXCEPTION
    WHEN OTHER THEN
        SYSTEM$LOG('error', 'Failed to migrate PREDEFINED_LABELS table. ' || :SQLCODE || ': ' || :SQLERRM);
        raise;
END;

CREATE OR REPLACE PROCEDURE INTERNAL.VALIDATE_LABEL_CONDITION(name string, condition string)
RETURNS STRING
AS
BEGIN
    let statement string := 'select case when \n' || condition || '\n then 1 else 0 end as "' || name || '" from reporting.enriched_query_history where false';
    execute immediate statement;
    return null;
EXCEPTION
    when statement_error then
        return 'Invalid condition SQL. Please check your syntax.' || :SQLERRM;
    WHEN OTHER THEN
        return 'Failure validating name & condition. Please check your syntax.' || :SQLERRM;
END;

-- Verify label name as quoted identifier is not same as any column name in view reporting.enriched_query_history.
CREATE OR REPLACE PROCEDURE INTERNAL.VALIDATE_LABEL_Name(name string)
RETURNS STRING
AS
BEGIN
    let statement string := 'select  "' || name || '" from reporting.enriched_query_history where false';
    execute immediate statement;
    return 'Label name can not be same as column name in view reporting.enriched_query_history. Please use a different label name.';
EXCEPTION
    when statement_error then
        return null;
    WHEN OTHER THEN
        return 'Failure validating name. Please check your syntax.' || :SQLERRM;
END;

CREATE OR REPLACE PROCEDURE INTERNAL.UPDATE_LABEL_VIEW()
RETURNS boolean
AS
BEGIN
    let labels cursor for select name, condition from internal.labels where group_name is null;
    let s string := $$
CREATE OR REPLACE VIEW REPORTING.LABELED_QUERY_HISTORY
COPY GRANTS
AS
SELECT *,$$;
    for label in labels do
         s := s || '\n\tcase when ' || label.condition || ' then true else false end as "' || label.name || '",';
    end for;

    let grouped_labels cursor for select group_name, name, condition from internal.labels where group_name is not null order by group_name, group_rank;
    let group_name string := null;
    for grp in grouped_labels do
        if (grp.group_name <> group_name or group_name is null) then
            if (group_name is not null) then
                s := s || ' end as "'|| group_name || '", ';
            end if;

            s := s || '\n\tcase ';
        end if;

        s := s || ' when ' || grp.condition || $$ then '$$ || grp.name || $$' $$;
        group_name := grp.group_name;
    end for;

    if (group_name is not null) then
        s := s || $$ else 'Other' end as "$$ || group_name || '", ';
    end if;


    s := s || '\n\t1 as not_used_internal\nFROM REPORTING.ENRICHED_QUERY_HISTORY';
    SYSTEM$LOG_INFO('Updating label definitions. Updated SQL: \n' || s);
    --return s;
    execute immediate s;
    return true;
END;

CREATE OR REPLACE PROCEDURE ADMIN.CREATE_LABEL(name text, grp text, rank number, condition text)
    RETURNS text
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
BEGIN
    if (:name is null) then
      return 'Name must not be null.';
    elseif (grp is null and rank is not null) then
      return 'Rank must only be set if Group name is also provided.';
    elseif (grp is not null and rank is null) then
      return 'Rank must provided if you are creating a grouped label.';
    end if;
    let outcome text := 'Failure validating name & condition. Please check your syntax.';

    outcome := (CALL INTERNAL.VALIDATE_LABEL_CONDITION(:name, :condition));

    if (outcome is not null) then
      return outcome;
    end if;

    outcome := (CALL INTERNAL.VALIDATE_LABEL_Name(:name));

    if (outcome is not null) then
      return outcome;
    end if;

    outcome := 'Duplicate label name found. Please use a distinct name.';
    BEGIN TRANSACTION;
        let cnt number := (SELECT COUNT(*) AS cnt FROM internal.labels WHERE name = :name);

        IF (cnt = 0) THEN
          INSERT INTO internal.labels ("NAME", "GROUP_NAME", "GROUP_RANK", "LABEL_CREATED_AT", "CONDITION", "LABEL_MODIFIED_AT") VALUES (:name, :grp, :rank, current_timestamp(), :condition, current_timestamp());
          outcome := null;
        END IF;

    COMMIT;
    CALL INTERNAL.UPDATE_LABEL_VIEW();
    return outcome;

END;

CREATE OR REPLACE PROCEDURE INTERNAL.INITIALIZE_LABELS()
    RETURNS boolean
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
BEGIN
    let labelcnt number := (SELECT COUNT(*) FROM internal.labels);

    let label_inited text := '';
    label_inited := (CALL INTERNAL.get_config('LABELS_INITED'));

    if (labelcnt > 0 OR label_inited = 'True') THEN
        SYSTEM$LOG_INFO('Predefined labels import is skipped. \n');
        RETURN FALSE;
    ELSE
        INSERT INTO INTERNAL.LABELS (NAME, GROUP_NAME, GROUP_RANK, LABEL_CREATED_AT, CONDITION, ENABLED, LABEL_MODIFIED_AT)
            SELECT NAME, GROUP_NAME, GROUP_RANK, LABEL_CREATED_AT, CONDITION, ENABLED, LABEL_CREATED_AT
            FROM INTERNAL.PREDEFINED_LABELS;
        CALL INTERNAL.SET_CONFIG('LABELS_INITED', 'True');
        SYSTEM$LOG_INFO('Predefined labels are imported into LABELS table. \n');
        RETURN TRUE;
    END IF;
END;


CREATE OR REPLACE PROCEDURE ADMIN.DELETE_LABEL(name text)
    RETURNS text
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
BEGIN
    if (:name is null) then
      return 'Name must not be null.';
    end if;

    DELETE FROM internal.labels where name = :name;
    CALL INTERNAL.UPDATE_LABEL_VIEW();
    return 'done';
END;

CREATE OR REPLACE PROCEDURE ADMIN.UPDATE_LABEL(oldname text, name text, grp text, rank number, condition text)
    RETURNS text
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
BEGIN
    if (name is null) then
      return 'Name must not be null.';
    elseif (grp is null and rank is not null) then
      return 'Rank must only be set if group name is also provided.';
    elseif (grp is not null and rank is null) then
      return 'Rank must provided if you are creating a grouped label.';
    end if;

    let outcome text := 'Duplicate label name found. Please use a distinct name.';

    outcome := (CALL INTERNAL.VALIDATE_LABEL_CONDITION(:name, :condition));

    if (outcome is not null) then
      return outcome;
    end if;

    outcome := (CALL INTERNAL.VALIDATE_LABEL_Name(:name));

    if (outcome is not null) then
      return outcome;
    end if;

    BEGIN TRANSACTION;

    -- Make sure that the old name exists once and the new name doesn't exist (assuming it is different from the old name)
    let oldcnt number := (SELECT COUNT(*) AS cnt FROM internal.labels WHERE name = :oldname);
    let newcnt number := (SELECT COUNT(*) AS cnt FROM internal.labels WHERE name = :name AND name <> :oldname);

    IF (oldcnt <> 1) THEN
      outcome := 'Label not found. Please refresh your page to see latest list of labels.';
    ELSEIF (newcnt <> 0) THEN
      outcome := 'A label with this name already exists. Please choose a distinct name.';
    ELSE
      UPDATE internal.labels SET  NAME = :name, GROUP_NAME = :grp, GROUP_RANK = :rank, CONDITION = :condition, LABEL_MODIFIED_AT = current_timestamp() WHERE NAME = :oldname;
      outcome := null;
    END IF;

    COMMIT;
    CALL INTERNAL.UPDATE_LABEL_VIEW();
    return outcome;
EXCEPTION
  WHEN OTHER THEN
      ROLLBACK;
      RAISE;
END;

CREATE VIEW CATALOG.LABELS IF NOT EXISTS AS SELECT * FROM INTERNAL.LABELS;

CREATE OR REPLACE PROCEDURE INTERNAL.POPULATE_PREDEFINED_LABELS()
    RETURNS text
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
BEGIN
    MERGE INTO internal.predefined_labels t
    USING (
        SELECT *
        from (values
                ('Large Results', 'rows_produced > 50000000'),
                ('Writes', 'query_type in (\'CREATE_TABLE_AS_SELECT\', \'INSERT\')'),
                ('Expanding Output', '10*bytes_scanned < BYTES_WRITTEN_TO_RESULT'),
                ('Full Scans', 'coalesce(partitions_scanned, 0) > coalesce(partitions_total, 1) * 0.95'),
                ('Long Compilation', 'COMPILATION_TIME > 100'),
                ('Long Queries', 'TOTAL_ELAPSED_TIME > 600000'),
                ('Expensive Queries', 'COST>0.5'),
                ('Accelerated Queries', 'QUERY_ACCELERATION_BYTES_SCANNED > 0')
             )) s (name, condition)
    ON t.name = s.name
    WHEN MATCHED THEN
    UPDATE
        SET t.GROUP_NAME = NULL, t.GROUP_RANK = NULL, t.CONDITION = s.condition, t.LABEL_MODIFIED_AT = current_timestamp()
    WHEN NOT MATCHED THEN
    INSERT
        ("NAME", "GROUP_NAME", "GROUP_RANK", "LABEL_CREATED_AT", "CONDITION", "LABEL_MODIFIED_AT")
        VALUES (s.name, NULL, NULL,  current_timestamp(), s.condition, current_timestamp());

    RETURN NULL;
EXCEPTION
  WHEN OTHER THEN
      ROLLBACK;
      RAISE;
END;

CREATE OR REPLACE PROCEDURE INTERNAL.VALIDATE_PREDEFINED_LABELS()
    RETURNS text
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
DECLARE
    outcome string;
    labels cursor for select "NAME", "CONDITION" from internal.predefined_labels;
BEGIN
    for record in labels do
        let name string := record."NAME";
        let condition string := record."CONDITION";
        outcome := (CALL INTERNAL.VALIDATE_LABEL_CONDITION(:name, :condition));
        IF (outcome is not null) then
            let res text := 'Predefined label  \'' || name || '\' with condition  \'' || condition || '\' is not valid';
            RETURN res;
        END IF;
    end for;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE PROCEDURE INTERNAL.MIGRATE_PREDEFINED_LABELS(gap_in_seconds NUMBER)
    RETURNS BOOLEAN
    LANGUAGE SQL
    EXECUTE AS OWNER
AS
$$
BEGIN
    let rowCount1 number := (
        WITH
        OLD_PREDEFINED_LABELS AS
            (SELECT name, LABEL_CREATED_AT FROM INTERNAL.PREDEFINED_LABELS WHERE TIMESTAMPDIFF(SECOND, LABEL_CREATED_AT, CURRENT_TIMESTAMP) > :gap_in_seconds),
        USER_LABELS AS
            (SELECT name, LABEL_MODIFIED_AT FROM INTERNAL.LABELS)
        SELECT count(*) from (select * from OLD_PREDEFINED_LABELS MINUS SELECT * FROM USER_LABELS) S
        );
    let rowCount2 number := (
        WITH
        OLD_PREDEFINED_LABELS AS
            (SELECT name, LABEL_CREATED_AT FROM INTERNAL.PREDEFINED_LABELS WHERE TIMESTAMPDIFF(SECOND, LABEL_CREATED_AT, CURRENT_TIMESTAMP) > :gap_in_seconds),
        USER_LABELS AS
            (SELECT name, LABEL_MODIFIED_AT FROM INTERNAL.LABELS)
        SELECT count(*) from (select * from USER_LABELS MINUS SELECT * FROM OLD_PREDEFINED_LABELS) S
        );

    IF (rowCount1 > 0 OR rowCount2 > 0) THEN
        RETURN FALSE;
    END IF;

    MERGE INTO internal.labels t
    USING internal.predefined_labels s
    ON t.name = s.name
    WHEN MATCHED THEN
    UPDATE
        SET t.GROUP_NAME = s.GROUP_NAME, t.GROUP_RANK = s.GROUP_RANK, t.CONDITION = s.condition, t.LABEL_MODIFIED_AT = s.LABEL_CREATED_AT
    WHEN NOT MATCHED THEN
    INSERT
        ("NAME", "GROUP_NAME", "GROUP_RANK", "LABEL_CREATED_AT", "CONDITION", "LABEL_MODIFIED_AT")
        VALUES (s.name, s.GROUP_NAME, s.GROUP_RANK,  S.LABEL_CREATED_AT, s.condition, S.LABEL_CREATED_AT);

    return TRUE;
END;
$$;
